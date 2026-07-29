import CryptoKit
import Foundation
import XZIPCore
import XZIPDomain

public struct CapturedTreeManifest: Hashable, Codable, Sendable {
    public let rootPath: String
    public let entries: [CapturedTreeManifestEntry]

    public var digest: Data {
        var encoder = CapturedTreeManifestEncoder()
        encoder.appendManifest(self)
        return Data(SHA256.hash(data: encoder.data))
    }

    public static func == (
        lhs: CapturedTreeManifest,
        rhs: CapturedTreeManifest
    ) -> Bool {
        utf8Data(lhs.rootPath) == utf8Data(rhs.rootPath)
            && lhs.entries == rhs.entries
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(utf8Data(rootPath))
        hasher.combine(entries)
    }

    public init(
        rootPath: String,
        entries: [CapturedTreeManifestEntry]
    ) throws {
        guard !Self.validatedComponents(rootPath).isEmpty else {
            throw CapturedTreeManifestError.invalidRootPath(rootPath)
        }

        let sortedEntries = entries.sorted {
            Self.utf8Precedes($0.relativePath, $1.relativePath)
        }
        var paths: Set<Data> = []
        var hasRoot = false
        for entry in sortedEntries {
            let components = try Self.validatedRelativeComponents(entry.relativePath)
            if components.isEmpty {
                guard !hasRoot else {
                    throw CapturedTreeManifestError.duplicateRelativePath("")
                }
                hasRoot = true
            }
            guard paths.insert(Data(entry.relativePath.utf8)).inserted else {
                throw CapturedTreeManifestError.duplicateRelativePath(entry.relativePath)
            }
        }
        guard hasRoot else {
            throw CapturedTreeManifestError.missingRootEntry
        }

        self.rootPath = rootPath
        self.entries = sortedEntries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            rootPath: container.decode(String.self, forKey: .rootPath),
            entries: container.decode(
                [CapturedTreeManifestEntry].self,
                forKey: .entries
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rootPath, forKey: .rootPath)
        try container.encode(entries, forKey: .entries)
    }

    static func capture(
        rootPath: String,
        rootNode: FileNode,
        parent: DirectoryHandle,
        fileSystem: any FileSystemOperations,
        listingPolicy: ArchiveResourcePolicy.Listing
    ) throws -> CapturedTreeManifest {
        var accumulator = CapturedTreeAccumulator(policy: listingPolicy)
        try accumulator.append(node: rootNode, relativePath: "")

        if rootNode.identity.kind == .directory {
            let root = try fileSystem.openDirectoryNoFollow(
                parent: parent,
                name: rootNode.name,
                expected: rootNode.identity
            )
            defer { root.close() }
            try appendChildren(
                directory: root,
                parentRelativePath: "",
                fileSystem: fileSystem,
                accumulator: &accumulator
            )
        }

        return try CapturedTreeManifest(
            rootPath: rootPath,
            entries: accumulator.entries
        )
    }

    private static func appendChildren(
        directory: DirectoryHandle,
        parentRelativePath: String,
        fileSystem: any FileSystemOperations,
        accumulator: inout CapturedTreeAccumulator
    ) throws {
        try fileSystem.forEachNodeNoFollow(directory) { node in
            let relativePath = parentRelativePath.isEmpty
                ? node.name
                : parentRelativePath + "/" + node.name
            try accumulator.append(node: node, relativePath: relativePath)
            guard node.identity.kind == .directory else { return }

            let child = try fileSystem.openDirectoryNoFollow(
                parent: directory,
                name: node.name,
                expected: node.identity
            )
            do {
                try appendChildren(
                    directory: child,
                    parentRelativePath: relativePath,
                    fileSystem: fileSystem,
                    accumulator: &accumulator
                )
                child.close()
            } catch {
                child.close()
                throw error
            }
        }
    }

    private static func validatedComponents(_ path: String) -> [Substring] {
        guard !path.isEmpty, !path.hasPrefix("/") else { return [] }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return []
        }
        return components
    }

    fileprivate static func validatedRelativeComponents(
        _ path: String
    ) throws -> [Substring] {
        if path.isEmpty { return [] }
        let components = validatedComponents(path)
        guard !components.isEmpty else {
            throw CapturedTreeManifestError.invalidRelativePath(path)
        }
        return components
    }

    private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private enum CodingKeys: String, CodingKey {
        case rootPath
        case entries
    }
}

public struct CapturedTreeManifestEntry: Hashable, Codable, Sendable {
    public let relativePath: String
    public let identity: FileNodeIdentity
    public let byteCount: UInt64
    public let allocatedByteCount: UInt64
    public let timestamps: FileTimestamps?

    let statusChangeTimestamp: FileTimestamp?
    let linkTarget: String?

    public static func == (
        lhs: CapturedTreeManifestEntry,
        rhs: CapturedTreeManifestEntry
    ) -> Bool {
        utf8Data(lhs.relativePath) == utf8Data(rhs.relativePath)
            && lhs.identity == rhs.identity
            && lhs.byteCount == rhs.byteCount
            && lhs.allocatedByteCount == rhs.allocatedByteCount
            && lhs.timestamps == rhs.timestamps
            && lhs.statusChangeTimestamp == rhs.statusChangeTimestamp
            && optionalUTF8Data(lhs.linkTarget) == optionalUTF8Data(rhs.linkTarget)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(utf8Data(relativePath))
        hasher.combine(identity)
        hasher.combine(byteCount)
        hasher.combine(allocatedByteCount)
        hasher.combine(timestamps)
        hasher.combine(statusChangeTimestamp)
        hasher.combine(optionalUTF8Data(linkTarget))
    }

    public init(
        relativePath: String,
        identity: FileNodeIdentity,
        byteCount: UInt64,
        allocatedByteCount: UInt64,
        timestamps: FileTimestamps?
    ) {
        self.init(
            relativePath: relativePath,
            identity: identity,
            byteCount: byteCount,
            allocatedByteCount: allocatedByteCount,
            timestamps: timestamps,
            statusChangeTimestamp: nil,
            linkTarget: nil
        )
    }

    init(relativePath: String, node: FileNode) {
        self.init(
            relativePath: relativePath,
            identity: node.identity,
            byteCount: node.byteCount,
            allocatedByteCount: node.allocatedByteCount,
            timestamps: node.timestamps,
            statusChangeTimestamp: node.statusChangeTimestamp,
            linkTarget: node.linkTarget
        )
    }

    private init(
        relativePath: String,
        identity: FileNodeIdentity,
        byteCount: UInt64,
        allocatedByteCount: UInt64,
        timestamps: FileTimestamps?,
        statusChangeTimestamp: FileTimestamp?,
        linkTarget: String?
    ) {
        self.relativePath = relativePath
        self.identity = identity
        self.byteCount = byteCount
        self.allocatedByteCount = allocatedByteCount
        self.timestamps = timestamps
        self.statusChangeTimestamp = statusChangeTimestamp
        self.linkTarget = linkTarget
    }
}

private struct CapturedTreeAccumulator {
    let policy: ArchiveResourcePolicy.Listing
    private(set) var entries: [CapturedTreeManifestEntry] = []
    private var paths: Set<Data> = []
    private var totalPathByteCount = 0

    init(policy: ArchiveResourcePolicy.Listing) {
        self.policy = policy
    }

    mutating func append(node: FileNode, relativePath: String) throws {
        let components = try CapturedTreeManifest.validatedRelativeComponents(
            relativePath
        )
        guard paths.insert(Data(relativePath.utf8)).inserted else {
            throw CapturedTreeManifestError.duplicateRelativePath(relativePath)
        }
        let (nextCount, countOverflow) = entries.count.addingReportingOverflow(1)
        let entryLimit = max(0, policy.listingHardCap)
        guard !countOverflow, nextCount <= entryLimit else {
            throw ArchiveFailure.resourceLimitExceeded(
                kind: .listingEntries,
                limit: UInt64(entryLimit),
                observed: countOverflow ? UInt64.max : UInt64(nextCount)
            )
        }

        let pathByteCount = relativePath.utf8.count
        let pathByteLimit = max(0, policy.maximumPathByteCount)
        guard pathByteCount <= pathByteLimit else {
            throw ArchiveFailure.resourceLimitExceeded(
                kind: .pathBytes,
                limit: UInt64(pathByteLimit),
                observed: UInt64(pathByteCount)
            )
        }

        let depthLimit = max(0, policy.maximumPathDepth)
        guard components.count <= depthLimit else {
            throw ArchiveFailure.resourceLimitExceeded(
                kind: .pathBytes,
                limit: UInt64(depthLimit),
                observed: UInt64(components.count)
            )
        }

        let totalLimit = max(0, policy.totalPathByteCap)
        let (nextTotal, overflow) = totalPathByteCount.addingReportingOverflow(
            pathByteCount
        )
        guard !overflow, nextTotal <= totalLimit else {
            throw ArchiveFailure.resourceLimitExceeded(
                kind: .pathBytes,
                limit: UInt64(totalLimit),
                observed: overflow ? UInt64.max : UInt64(nextTotal)
            )
        }

        totalPathByteCount = nextTotal
        entries.append(CapturedTreeManifestEntry(
            relativePath: relativePath,
            node: node
        ))
    }
}

private struct CapturedTreeManifestEncoder {
    private var bytes: [UInt8] = []

    var data: Data { Data(bytes) }

    mutating func appendManifest(_ manifest: CapturedTreeManifest) {
        append("xzip-captured-tree-v1")
        append(manifest.rootPath)
        append(UInt64(manifest.entries.count))
        for entry in manifest.entries {
            append(entry.relativePath)
            append(entry.identity.kind.rawValue)
            append(entry.identity.device)
            append(entry.identity.inode)
            append(entry.identity.generation)
            append(entry.byteCount)
            append(entry.allocatedByteCount)
            append(entry.timestamps?.access)
            append(entry.timestamps?.modification)
            append(entry.statusChangeTimestamp)
            append(entry.linkTarget)
        }
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

private func utf8Data(_ value: String) -> Data {
    Data(value.utf8)
}

private func optionalUTF8Data(_ value: String?) -> Data? {
    value.map(utf8Data)
}

enum CapturedTreeManifestError: Error, Equatable {
    case invalidRootPath(String)
    case invalidRelativePath(String)
    case duplicateRelativePath(String)
    case missingRootEntry
}
