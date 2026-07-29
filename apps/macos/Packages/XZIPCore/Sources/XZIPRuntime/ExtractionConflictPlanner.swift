import CryptoKit
import Foundation
import XZIPCore
import XZIPDomain

enum ExtractionPublicationAction: Equatable, Sendable {
    case publish
    case mergeDirectory
    case fail
    case skip
    case keepBoth(finalPath: String)
    case replace
    case ask
}

struct ExtractionPublicationExpectation: Equatable, Sendable {
    let originalPath: String
    let existing: FileNode?
    let action: ExtractionPublicationAction
}

struct ExtractionPublicationPlan: Sendable {
    let inventory: ExtractionInventory
    let conflicts: [ExtractionConflictSummary]
    let destructiveReplacementPaths: [String]
    let digest: ExtractionPlanDigest
    let publicationExpectations: [String: ExtractionPublicationExpectation]
    let publicationBinding: [ExtractionPublicationBindingEntry]
    let replacementSnapshots: [String: CapturedTreeManifest]
}

struct ExtractionConflictPlanner: Sendable {
    let fileSystem: any FileSystemOperations

    func plan(
        inventory: ExtractionInventory,
        selectedEntries: [String],
        destination: DirectoryHandle,
        conflictPolicy: OperationConflictPolicy,
        preserveTimestamps: Bool,
        resourcePolicy: ArchiveResourcePolicy
    ) throws -> ExtractionPublicationPlan {
        let replacementRoots = conflictPolicy == .replace
            ? selectedReplacementRoots(
                inventory: inventory,
                selectedEntries: selectedEntries
            )
            : []
        let publicationExpectations = try makePublicationExpectations(
            inventory: inventory,
            replacementRoots: replacementRoots,
            destination: destination,
            conflictPolicy: conflictPolicy
        )
        let roots: [String]
        if conflictPolicy == .replace {
            roots = publicationExpectations.values.compactMap { expectation in
                expectation.action == .replace && expectation.existing != nil
                    ? expectation.originalPath
                    : nil
            }.sorted(by: utf8Precedes)
        } else {
            roots = Set(inventory.entries.compactMap { entry in
                entry.path.split(separator: "/", maxSplits: 1).first.map(String.init)
            }).sorted(by: utf8Precedes)
        }

        var actions: [ConflictAction] = []
        var replacementSnapshots: [String: CapturedTreeManifest] = [:]

        for root in roots {
            let existing: FileNode
            if conflictPolicy == .replace {
                guard let approvedExisting = publicationExpectations[root]?.existing else {
                    continue
                }
                existing = approvedExisting
            } else {
                guard let currentExisting = try fileSystem.statNoFollow(
                    parent: destination,
                    name: root
                ) else {
                    continue
                }
                existing = currentExisting
            }

            let replacesDirectory = conflictPolicy == .replace
                && existing.identity.kind == .directory
            actions.append(ConflictAction(
                relativePath: root,
                action: actionName(
                    policy: conflictPolicy,
                    existingKind: existing.identity.kind
                ),
                existing: existing,
                replacesDirectorySubtree: replacesDirectory
            ))

            if conflictPolicy == .replace {
                replacementSnapshots[root] = try captureManifest(
                    rootPath: root,
                    rootNode: existing,
                    destination: destination,
                    publicationExpectations: publicationExpectations,
                    listingPolicy: resourcePolicy.listing
                )
            }
        }

        actions.sort { utf8Precedes($0.relativePath, $1.relativePath) }
        let destructiveReplacementPaths = conflictPolicy == .replace
            ? actions.map(\.relativePath)
            : []

        var encoder = CanonicalExtractionPlanEncoder()
        encoder.appendPlan(
            inventory: inventory,
            conflictPolicy: conflictPolicy,
            preserveTimestamps: preserveTimestamps,
            actions: actions,
            replacementSnapshots: replacementSnapshots
        )
        let digest = ExtractionPlanDigest(
            bytes: Data(SHA256.hash(data: encoder.data))
        )
        let publicationBinding = makePublicationBinding(
            publicationExpectations
        )

        return ExtractionPublicationPlan(
            inventory: inventory,
            conflicts: actions.map { action in
                ExtractionConflictSummary(
                    relativePath: action.relativePath,
                    existingByteCount: action.existing.byteCount,
                    existingModificationDate: modificationDate(
                        action.existing.timestamps?.modification
                    ),
                    replacesDirectorySubtree: action.replacesDirectorySubtree
                )
            },
            destructiveReplacementPaths: destructiveReplacementPaths,
            digest: digest,
            publicationExpectations: publicationExpectations,
            publicationBinding: publicationBinding,
            replacementSnapshots: replacementSnapshots
        )
    }

    private func makePublicationBinding(
        _ expectations: [String: ExtractionPublicationExpectation]
    ) -> [ExtractionPublicationBindingEntry] {
        expectations.values.map { expectation in
            let expectedIdentity = expectation.existing.map { node in
                ExtractionPublicationNodeIdentity(
                    device: node.identity.device,
                    inode: node.identity.inode,
                    generation: node.identity.generation,
                    kindRawValue: node.identity.kind.rawValue
                )
            }
            let decision: ExtractionPublicationDecision
            switch expectation.action {
            case .publish:
                decision = .publish
            case .mergeDirectory:
                decision = .mergeDirectory
            case .fail:
                decision = .fail
            case .skip:
                decision = .skip
            case let .keepBoth(finalPath):
                decision = .keepBoth(finalPath: finalPath)
            case .replace:
                decision = .replace
            case .ask:
                decision = .ask
            }
            return ExtractionPublicationBindingEntry(
                originalPath: expectation.originalPath,
                expectedIdentity: expectedIdentity,
                decision: decision
            )
        }.sorted { utf8Precedes($0.originalPath, $1.originalPath) }
    }

    private func selectedReplacementRoots(
        inventory: ExtractionInventory,
        selectedEntries: [String]
    ) -> Set<String> {
        let stagedPaths = Set(inventory.entries.map(\.path))
            .union(inventory.implicitDirectories)
        guard !selectedEntries.isEmpty else {
            return Set(stagedPaths.compactMap { path in
                path.split(separator: "/", maxSplits: 1).first.map(String.init)
            })
        }

        let representedSelections = Set(selectedEntries.filter { selection in
            stagedPaths.contains(selection)
                || stagedPaths.contains { $0.hasPrefix(selection + "/") }
        })
        return Set(representedSelections.filter { candidate in
            !representedSelections.contains { ancestor in
                ancestor != candidate && candidate.hasPrefix(ancestor + "/")
            }
        })
    }

    private func replacementTraversalAncestors(
        of replacementRoots: Set<String>
    ) -> Set<String> {
        var ancestors = Set<String>()
        for root in replacementRoots {
            let components = root.split(separator: "/").map(String.init)
            for depth in 1..<components.count {
                ancestors.insert(components.prefix(depth).joined(separator: "/"))
            }
        }
        return ancestors
    }

    private func makePublicationExpectations(
        inventory: ExtractionInventory,
        replacementRoots: Set<String>,
        destination: DirectoryHandle,
        conflictPolicy: OperationConflictPolicy
    ) throws -> [String: ExtractionPublicationExpectation] {
        var kinds = Dictionary(uniqueKeysWithValues: inventory.implicitDirectories.map {
            ($0, ExtractionNodeKind.directory)
        })
        for entry in inventory.entries {
            kinds[entry.path] = entry.kind
        }
        var childrenByParent: [String: [String]] = [:]
        for path in kinds.keys {
            let components = path.split(separator: "/").map(String.init)
            guard let name = components.last else { continue }
            let parent = components.dropLast().joined(separator: "/")
            childrenByParent[parent, default: []].append(name)
        }
        for parent in childrenByParent.keys {
            childrenByParent[parent]?.sort(by: utf8Precedes)
        }

        let traversalAncestors = replacementTraversalAncestors(
            of: replacementRoots
        )
        var expectations: [String: ExtractionPublicationExpectation] = [:]
        try appendPublicationExpectations(
            parent: destination,
            parentPath: "",
            kinds: kinds,
            replacementRoots: replacementRoots,
            traversalAncestors: traversalAncestors,
            childrenByParent: childrenByParent,
            conflictPolicy: conflictPolicy,
            expectations: &expectations
        )
        return expectations
    }

    private func appendPublicationExpectations(
        parent: DirectoryHandle,
        parentPath: String,
        kinds: [String: ExtractionNodeKind],
        replacementRoots: Set<String>,
        traversalAncestors: Set<String>,
        childrenByParent: [String: [String]],
        conflictPolicy: OperationConflictPolicy,
        expectations: inout [String: ExtractionPublicationExpectation]
    ) throws {
        for name in childrenByParent[parentPath, default: []] {
            let path = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
            guard let stagedKind = kinds[path] else { continue }
            let existing = try fileSystem.statNoFollow(parent: parent, name: name)

            guard let existing else {
                expectations[path] = ExtractionPublicationExpectation(
                    originalPath: path,
                    existing: nil,
                    action: .publish
                )
                continue
            }

            if stagedKind == .directory,
               existing.identity.kind == .directory,
               conflictPolicy != .replace || traversalAncestors.contains(path)
            {
                expectations[path] = ExtractionPublicationExpectation(
                    originalPath: path,
                    existing: existing,
                    action: .mergeDirectory
                )
                let directory = try fileSystem.openDirectoryNoFollow(
                    parent: parent,
                    name: name,
                    expected: existing.identity
                )
                do {
                    try appendPublicationExpectations(
                        parent: directory,
                        parentPath: path,
                        kinds: kinds,
                        replacementRoots: replacementRoots,
                        traversalAncestors: traversalAncestors,
                        childrenByParent: childrenByParent,
                        conflictPolicy: conflictPolicy,
                        expectations: &expectations
                    )
                    directory.close()
                } catch {
                    directory.close()
                    throw error
                }
                continue
            }

            let action: ExtractionPublicationAction
            switch conflictPolicy {
            case .fail:
                action = .fail
            case .skip:
                action = .skip
            case .keepBoth:
                action = .keepBoth(finalPath: try keepBothPath(
                    originalPath: path,
                    parent: parent
                ))
            case .replace:
                action = replacementRoots.contains(path) ? .replace : .fail
            case .ask:
                action = .ask
            }
            expectations[path] = ExtractionPublicationExpectation(
                originalPath: path,
                existing: existing,
                action: action
            )
        }
    }

    private func keepBothPath(
        originalPath: String,
        parent: DirectoryHandle
    ) throws -> String {
        let components = originalPath.split(separator: "/").map(String.init)
        guard let originalName = components.last else {
            throw FileSystemOperationError.invalidComponent(originalPath)
        }
        let parentPath = components.dropLast().joined(separator: "/")
        for index in 1...10_000 {
            let candidateName = keepBothName(originalName, index: index)
            guard try fileSystem.statNoFollow(parent: parent, name: candidateName) == nil else {
                continue
            }
            return parentPath.isEmpty
                ? candidateName
                : "\(parentPath)/\(candidateName)"
        }
        throw ArchiveFailure.destinationConflict(path: originalPath)
    }

    private func keepBothName(_ name: String, index: Int) -> String {
        guard let dot = name.lastIndex(of: "."),
              dot != name.startIndex,
              dot != name.index(before: name.endIndex)
        else {
            return "\(name)_\(index)"
        }
        return "\(name[..<dot])_\(index)\(name[dot...])"
    }

    private func captureManifest(
        rootPath: String,
        rootNode: FileNode,
        destination: DirectoryHandle,
        publicationExpectations: [String: ExtractionPublicationExpectation],
        listingPolicy: ArchiveResourcePolicy.Listing
    ) throws -> CapturedTreeManifest {
        let components = rootPath.split(separator: "/").map(String.init)
        let parentComponents = Array(components.dropLast())
        guard !parentComponents.isEmpty else {
            return try CapturedTreeManifest.capture(
                rootPath: rootPath,
                rootNode: rootNode,
                parent: destination,
                fileSystem: fileSystem,
                listingPolicy: listingPolicy
            )
        }
        let parentPath = parentComponents.joined(separator: "/")
        guard let expectedParent = publicationExpectations[parentPath]?.existing?.identity else {
            throw ArchiveFailure.extractionPlanChanged
        }
        let parent = try fileSystem.openRelativeDirectoryNoFollow(
            root: destination,
            components: parentComponents,
            expected: expectedParent
        )
        defer { parent.close() }
        return try CapturedTreeManifest.capture(
            rootPath: rootPath,
            rootNode: rootNode,
            parent: parent,
            fileSystem: fileSystem,
            listingPolicy: listingPolicy
        )
    }

    private func actionName(
        policy: OperationConflictPolicy,
        existingKind: ExtractionNodeKind
    ) -> String {
        switch policy {
        case .replace:
            return existingKind == .directory
                ? "replace-directory-subtree"
                : "replace-node"
        case .keepBoth:
            return "keep-both"
        case .skip:
            return "skip"
        case .ask:
            return "ask"
        case .fail:
            return "fail"
        }
    }

    private func modificationDate(_ timestamp: FileTimestamp?) -> Date? {
        guard let timestamp else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(timestamp.seconds)
                + TimeInterval(timestamp.nanoseconds) / 1_000_000_000
        )
    }
}

private struct ConflictAction {
    let relativePath: String
    let action: String
    let existing: FileNode
    let replacesDirectorySubtree: Bool
}

private struct CanonicalExtractionPlanEncoder {
    private var bytes: [UInt8] = []

    var data: Data { Data(bytes) }

    mutating func appendPlan(
        inventory: ExtractionInventory,
        conflictPolicy: OperationConflictPolicy,
        preserveTimestamps: Bool,
        actions: [ConflictAction],
        replacementSnapshots: [String: CapturedTreeManifest]
    ) {
        append("xzip-extraction-plan-v1")
        append(conflictPolicy.rawValue)
        append(preserveTimestamps)

        let entries = inventory.entries.sorted {
            utf8Precedes($0.path, $1.path)
        }
        append(UInt64(entries.count))
        for entry in entries {
            append(entry.path)
            append(entry.kind.rawValue)
            append(entry.size)
            append(entry.isExplicitDirectory)
            append(entry.linkTarget)
            append(entry.posixMode.map(UInt64.init))
        }

        let implicitDirectories = inventory.implicitDirectories.sorted(
            by: utf8Precedes
        )
        append(UInt64(implicitDirectories.count))
        for directory in implicitDirectories {
            append(directory)
        }

        append(UInt64(actions.count))
        for action in actions {
            append(action.relativePath)
            append(action.action)
        }

        let snapshots = replacementSnapshots.values.sorted {
            utf8Precedes($0.rootPath, $1.rootPath)
        }
        append(UInt64(snapshots.count))
        for snapshot in snapshots {
            append(snapshot.rootPath)
            append(UInt64(snapshot.entries.count))
            for entry in snapshot.entries {
                let path = entry.relativePath.isEmpty
                    ? snapshot.rootPath
                    : snapshot.rootPath + "/" + entry.relativePath
                append(path)
                append(entry.identity.kind.rawValue)
                append(entry.identity.device)
                append(entry.identity.inode)
                append(entry.identity.generation)
                append(entry.byteCount)
                append(entry.allocatedByteCount)
                append(entry.timestamps?.modification)
                append(entry.statusChangeTimestamp)
                append(entry.linkTarget)
            }
        }
    }

    private mutating func append(_ value: Bool) {
        bytes.append(value ? 1 : 0)
    }

    private mutating func append(_ value: UInt64) {
        bytes.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
    }

    private mutating func append(_ value: Int64) {
        append(UInt64(bitPattern: value))
    }

    private mutating func append(_ value: Int32) {
        let encoded = UInt32(bitPattern: value).bigEndian
        bytes.append(contentsOf: withUnsafeBytes(of: encoded, Array.init))
    }

    private mutating func append(_ value: String) {
        let encoded = Array(value.utf8)
        append(UInt64(encoded.count))
        bytes.append(contentsOf: encoded)
    }

    private mutating func append(_ value: UInt64?) {
        guard let value else {
            bytes.append(0)
            return
        }
        bytes.append(1)
        append(value)
    }

    private mutating func append(_ value: String?) {
        guard let value else {
            bytes.append(0)
            return
        }
        bytes.append(1)
        append(value)
    }

    private mutating func append(_ value: FileTimestamp?) {
        guard let value else {
            bytes.append(0)
            return
        }
        bytes.append(1)
        append(value.seconds)
        append(value.nanoseconds)
    }
}

private func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
