import CryptoKit
import Foundation
import XCTest
@testable import XZIPCore
@testable import XZIPDomain
@testable import XZIPRuntime

final class ExtractionConflictPlannerTests: XCTestCase {
    func testReplacePlanListsWholeConflictingDirectoryAndDigestIsStable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        let folder = destination.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(
            to: folder.appendingPathComponent("old.txt")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let inventory = try ExtractionInventory.validated(
            entries: [
                .init(
                    path: "folder",
                    kind: .directory,
                    size: 0,
                    linkTarget: nil,
                    isExplicitDirectory: true
                ),
                .init(
                    path: "folder/new.txt",
                    kind: .regularFile,
                    size: 3,
                    linkTarget: nil,
                    isExplicitDirectory: false
                )
            ],
            advertisedDictionaryByteCount: 0,
            policy: .production
        )
        let fileSystem = DarwinFileSystemOperations()
        let destinationHandle = try fileSystem.openDirectoryNoFollow(at: destination)
        defer { destinationHandle.close() }
        let planner = ExtractionConflictPlanner(fileSystem: fileSystem)

        let first = try planner.plan(
            inventory: inventory,
            selectedEntries: [],
            destination: destinationHandle,
            conflictPolicy: .replace,
            preserveTimestamps: true,
            resourcePolicy: .production
        )
        let second = try planner.plan(
            inventory: inventory,
            selectedEntries: [],
            destination: destinationHandle,
            conflictPolicy: .replace,
            preserveTimestamps: true,
            resourcePolicy: .production
        )

        XCTAssertEqual(first.destructiveReplacementPaths, ["folder"])
        XCTAssertEqual(first.conflicts.map(\.relativePath), ["folder"])
        XCTAssertEqual(first.digest, second.digest)
        XCTAssertTrue(first.conflicts[0].replacesDirectorySubtree)
    }

    func testReplaceDirectoryPlanExposesApprovedCapturedManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        let folder = destination.appendingPathComponent("folder", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: nested.appendingPathComponent("b.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = DarwinFileSystemOperations()
        let destinationHandle = try fileSystem.openDirectoryNoFollow(at: destination)
        defer { destinationHandle.close() }
        let existingRootIdentity = try XCTUnwrap(
            fileSystem.statNoFollow(parent: destinationHandle, name: "folder")
        ).identity
        let inventory = try ExtractionInventory.validated(
            entries: [
                .init(
                    path: "folder/new.txt",
                    kind: .regularFile,
                    size: 3,
                    linkTarget: nil,
                    isExplicitDirectory: false
                )
            ],
            advertisedDictionaryByteCount: 0,
            policy: .production
        )

        let plan = try ExtractionConflictPlanner(fileSystem: fileSystem).plan(
            inventory: inventory,
            selectedEntries: [],
            destination: destinationHandle,
            conflictPolicy: .replace,
            preserveTimestamps: true,
            resourcePolicy: .production
        )
        let manifest = try XCTUnwrap(plan.replacementSnapshots["folder"])

        XCTAssertEqual(manifest.entries.map(\.relativePath), [
            "",
            "a.txt",
            "nested",
            "nested/b.txt"
        ])
        XCTAssertEqual(manifest.entries.first?.identity, existingRootIdentity)
    }

    func testReplacePlanScopesDestructionToSelectedNestedDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        let existingRoot = destination.appendingPathComponent("root", isDirectory: true)
        let nested = existingRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(
            to: existingRoot.appendingPathComponent("keep.txt")
        )
        try Data("old".utf8).write(
            to: nested.appendingPathComponent("old.txt")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let inventory = try ExtractionInventory.validated(
            entries: [
                .init(
                    path: "root/nested",
                    kind: .directory,
                    size: 0,
                    linkTarget: nil,
                    isExplicitDirectory: true
                ),
                .init(
                    path: "root/nested/new.txt",
                    kind: .regularFile,
                    size: 3,
                    linkTarget: nil,
                    isExplicitDirectory: false
                )
            ],
            advertisedDictionaryByteCount: 0,
            policy: .production
        )
        let plan = try makePlan(
            inventory: inventory,
            selectedEntries: ["root/nested"],
            destination: destination
        )

        XCTAssertEqual(plan.destructiveReplacementPaths, ["root/nested"])
        XCTAssertEqual(plan.conflicts.map(\.relativePath), ["root/nested"])
        XCTAssertEqual(plan.publicationExpectations["root"]?.action, .mergeDirectory)
        XCTAssertEqual(plan.publicationExpectations["root/nested"]?.action, .replace)
        XCTAssertEqual(
            plan.publicationBinding.first { $0.originalPath == "root" }?.decision,
            .mergeDirectory
        )
        XCTAssertFalse(plan.publicationBinding.contains {
            $0.originalPath == "root" && $0.decision == .replace
        })
    }

    func testReplacePlanScopesDestructionToSelectedFileUnderImplicitDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        let existingRoot = destination.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(
            at: existingRoot,
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(
            to: existingRoot.appendingPathComponent("keep.txt")
        )
        try Data("old".utf8).write(
            to: existingRoot.appendingPathComponent("selected.txt")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let inventory = try ExtractionInventory.validated(
            entries: [
                .init(
                    path: "root/selected.txt",
                    kind: .regularFile,
                    size: 3,
                    linkTarget: nil,
                    isExplicitDirectory: false
                )
            ],
            advertisedDictionaryByteCount: 0,
            policy: .production
        )
        let plan = try makePlan(
            inventory: inventory,
            selectedEntries: ["root/selected.txt"],
            destination: destination
        )

        XCTAssertEqual(plan.destructiveReplacementPaths, ["root/selected.txt"])
        XCTAssertEqual(plan.conflicts.map(\.relativePath), ["root/selected.txt"])
        XCTAssertEqual(plan.publicationExpectations["root"]?.action, .mergeDirectory)
        XCTAssertEqual(plan.publicationExpectations["root/selected.txt"]?.action, .replace)
        XCTAssertFalse(plan.publicationBinding.contains {
            $0.originalPath == "root" && $0.decision == .replace
        })
    }

    func testReplacePlanUsesImplicitTopLevelDirectoryAsFullExtractionRoot() throws {
        let fixture = try PlannerFixture.implicitDirectoryConflict()
        defer { fixture.remove() }

        let plan = try makePlan(
            inventory: fixture.inventory,
            selectedEntries: [],
            destination: fixture.destination
        )

        XCTAssertEqual(plan.destructiveReplacementPaths, ["folder"])
        XCTAssertEqual(plan.conflicts.map(\.relativePath), ["folder"])
        XCTAssertEqual(plan.publicationExpectations["folder"]?.action, .replace)
        XCTAssertEqual(plan.publicationBinding.map(\.decision), [.replace])
    }

    func testReplacePlanUsesSelectedImplicitDirectoryAsReplacementRoot() throws {
        let fixture = try PlannerFixture.implicitDirectoryConflict()
        defer { fixture.remove() }

        let plan = try makePlan(
            inventory: fixture.inventory,
            selectedEntries: ["folder"],
            destination: fixture.destination
        )

        XCTAssertEqual(plan.destructiveReplacementPaths, ["folder"])
        XCTAssertEqual(plan.conflicts.map(\.relativePath), ["folder"])
        XCTAssertEqual(plan.publicationExpectations["folder"]?.action, .replace)
    }

    func testReplacePlanKeepsImplicitDirectoryAsMergeAncestorForSelectedDescendant() throws {
        let fixture = try PlannerFixture.implicitDirectoryConflict()
        defer { fixture.remove() }
        try Data("old".utf8).write(
            to: fixture.destination.appendingPathComponent("folder/new.txt")
        )

        let plan = try makePlan(
            inventory: fixture.inventory,
            selectedEntries: ["folder/new.txt"],
            destination: fixture.destination
        )

        XCTAssertEqual(plan.destructiveReplacementPaths, ["folder/new.txt"])
        XCTAssertEqual(plan.publicationExpectations["folder"]?.action, .mergeDirectory)
        XCTAssertEqual(plan.publicationExpectations["folder/new.txt"]?.action, .replace)
    }

    func testReplacePlanCollapsesOverlappingSelectionsToOneRoot() throws {
        let fixture = try PlannerFixture.implicitDirectoryConflict()
        defer { fixture.remove() }

        let plan = try makePlan(
            inventory: fixture.inventory,
            selectedEntries: ["folder", "folder/new.txt"],
            destination: fixture.destination
        )

        XCTAssertEqual(plan.destructiveReplacementPaths, ["folder"])
        XCTAssertEqual(plan.conflicts.map(\.relativePath), ["folder"])
        XCTAssertEqual(plan.publicationBinding.map(\.originalPath), ["folder"])
        XCTAssertEqual(plan.publicationBinding.map(\.decision), [.replace])
    }

    func testReplacePlanScopesDisjointSelectionsUnderCommonMergeAncestor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        let left = destination.appendingPathComponent("root/left", isDirectory: true)
        let right = destination.appendingPathComponent("root/right", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: left.appendingPathComponent("old.txt"))
        try Data("old".utf8).write(to: right.appendingPathComponent("new.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try ExtractionInventory.validated(
            entries: [
                .init(
                    path: "root/left/new.txt",
                    kind: .regularFile,
                    size: 3,
                    linkTarget: nil,
                    isExplicitDirectory: false
                ),
                .init(
                    path: "root/right/new.txt",
                    kind: .regularFile,
                    size: 3,
                    linkTarget: nil,
                    isExplicitDirectory: false
                )
            ],
            advertisedDictionaryByteCount: 0,
            policy: .production
        )

        let plan = try makePlan(
            inventory: inventory,
            selectedEntries: ["root/left", "root/right/new.txt"],
            destination: destination
        )

        XCTAssertEqual(
            plan.destructiveReplacementPaths,
            ["root/left", "root/right/new.txt"]
        )
        XCTAssertEqual(plan.publicationExpectations["root"]?.action, .mergeDirectory)
        XCTAssertEqual(plan.publicationExpectations["root/left"]?.action, .replace)
        XCTAssertEqual(plan.publicationExpectations["root/right"]?.action, .mergeDirectory)
        XCTAssertEqual(
            plan.publicationExpectations["root/right/new.txt"]?.action,
            .replace
        )
    }

    func testReplacePlanReplacesFileAndSymlinkWithImplicitDirectoryRoot() throws {
        for existingKind in [ExtractionNodeKind.regularFile, .symbolicLink] {
            let fixture = try PlannerFixture.implicitDirectoryConflict(
                existingKind: existingKind
            )
            defer { fixture.remove() }

            let plan = try makePlan(
                inventory: fixture.inventory,
                selectedEntries: [],
                destination: fixture.destination
            )

            XCTAssertEqual(plan.destructiveReplacementPaths, ["folder"])
            XCTAssertEqual(plan.publicationExpectations["folder"]?.action, .replace)
        }
    }

    func testLateChildChangesReplacePlanDigest() throws {
        let fixture = try PlannerFixture.directoryConflict()
        defer { fixture.remove() }
        let first = try fixture.makePlan()

        try Data("late".utf8).write(
            to: fixture.destination
                .appendingPathComponent("folder/late.txt")
        )
        let second = try fixture.makePlan()

        XCTAssertNotEqual(first.digest, second.digest)
    }

    func testSameSizeChildRewriteWithRestoredMTimeChangesDigest() throws {
        let fixture = try PlannerFixture.directoryConflict()
        defer { fixture.remove() }
        let child = fixture.destination
            .appendingPathComponent("folder/old.txt")
        let originalMTime = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: child.path)[.modificationDate]
                as? Date
        )
        let first = try fixture.makePlan()
        Thread.sleep(forTimeInterval: 1.1)

        try Data("new".utf8).write(to: child)
        try FileManager.default.setAttributes(
            [.modificationDate: originalMTime],
            ofItemAtPath: child.path
        )
        let second = try fixture.makePlan()

        XCTAssertNotEqual(first.digest, second.digest)
    }

    func testSameSizeTopLevelRewriteWithRestoredMTimeChangesDigest() throws {
        let fixture = try PlannerFixture.fileConflict()
        defer { fixture.remove() }
        let file = fixture.destination.appendingPathComponent("item.txt")
        let originalMTime = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
                as? Date
        )
        let first = try fixture.makePlan()
        Thread.sleep(forTimeInterval: 1.1)

        try Data("new".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: originalMTime],
            ofItemAtPath: file.path
        )
        let second = try fixture.makePlan()

        XCTAssertNotEqual(first.digest, second.digest)
    }

    func testTopLevelFileReplacedBySymlinkChangesDigest() throws {
        let fixture = try PlannerFixture.fileConflict()
        defer { fixture.remove() }
        let file = fixture.destination.appendingPathComponent("item.txt")
        let first = try fixture.makePlan()

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(
            atPath: file.path,
            withDestinationPath: "target"
        )
        let second = try fixture.makePlan()

        XCTAssertNotEqual(first.digest, second.digest)
    }
}

private func makePlan(
    inventory: ExtractionInventory,
    selectedEntries: [String],
    destination: URL,
    resourcePolicy: ArchiveResourcePolicy = .production
) throws -> ExtractionPublicationPlan {
    let fileSystem = DarwinFileSystemOperations()
    let destinationHandle = try fileSystem.openDirectoryNoFollow(at: destination)
    defer { destinationHandle.close() }
    return try ExtractionConflictPlanner(fileSystem: fileSystem).plan(
        inventory: inventory,
        selectedEntries: selectedEntries,
        destination: destinationHandle,
        conflictPolicy: .replace,
        preserveTimestamps: true,
        resourcePolicy: resourcePolicy
    )
}

private struct PlannerFixture {
    let root: URL
    let destination: URL
    let inventory: ExtractionInventory
    let fileSystem: DarwinFileSystemOperations

    static func directoryConflict() throws -> PlannerFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        let folder = destination.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(
            to: folder.appendingPathComponent("old.txt")
        )
        let inventory = try ExtractionInventory.validated(
            entries: [
                .init(
                    path: "folder",
                    kind: .directory,
                    size: 0,
                    linkTarget: nil,
                    isExplicitDirectory: true
                ),
                .init(
                    path: "folder/new.txt",
                    kind: .regularFile,
                    size: 3,
                    linkTarget: nil,
                    isExplicitDirectory: false
                )
            ],
            advertisedDictionaryByteCount: 0,
            policy: .production
        )
        return PlannerFixture(
            root: root,
            destination: destination,
            inventory: inventory,
            fileSystem: DarwinFileSystemOperations()
        )
    }

    static func implicitDirectoryConflict(
        existingKind: ExtractionNodeKind = .directory
    ) throws -> PlannerFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let folder = destination.appendingPathComponent("folder")
        switch existingKind {
        case .directory:
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: false
            )
            try Data("keep".utf8).write(
                to: folder.appendingPathComponent("unrelated.txt")
            )
        case .regularFile:
            try Data("old".utf8).write(to: folder)
        case .symbolicLink:
            try FileManager.default.createSymbolicLink(
                atPath: folder.path,
                withDestinationPath: "target"
            )
        default:
            XCTFail("Unsupported fixture kind: \(existingKind)")
        }
        let inventory = try ExtractionInventory.validated(
            entries: [
                .init(
                    path: "folder/new.txt",
                    kind: .regularFile,
                    size: 3,
                    linkTarget: nil,
                    isExplicitDirectory: false
                )
            ],
            advertisedDictionaryByteCount: 0,
            policy: .production
        )
        return PlannerFixture(
            root: root,
            destination: destination,
            inventory: inventory,
            fileSystem: DarwinFileSystemOperations()
        )
    }

    static func fileConflict() throws -> PlannerFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(
            to: destination.appendingPathComponent("item.txt")
        )
        let inventory = try ExtractionInventory.validated(
            entries: [
                .init(
                    path: "item.txt",
                    kind: .regularFile,
                    size: 3,
                    linkTarget: nil,
                    isExplicitDirectory: false
                )
            ],
            advertisedDictionaryByteCount: 0,
            policy: .production
        )
        return PlannerFixture(
            root: root,
            destination: destination,
            inventory: inventory,
            fileSystem: DarwinFileSystemOperations()
        )
    }

    func makePlan() throws -> ExtractionPublicationPlan {
        let destinationHandle = try fileSystem.openDirectoryNoFollow(
            at: destination
        )
        defer { destinationHandle.close() }
        return try ExtractionConflictPlanner(fileSystem: fileSystem).plan(
            inventory: inventory,
            selectedEntries: [],
            destination: destinationHandle,
            conflictPolicy: .replace,
            preserveTimestamps: true,
            resourcePolicy: .production
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
