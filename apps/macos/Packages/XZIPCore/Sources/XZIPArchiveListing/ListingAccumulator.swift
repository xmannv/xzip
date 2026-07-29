import struct Archive.ArchiveEntry
import Foundation
import XZIPCore
import XZIPDomain

struct ListingAccumulator {
    private let limit: Int
    private let policy: ArchiveResourcePolicy.Listing
    private var entries: [XZIPCore.ArchiveEntry] = []
    private var totalPathBytes = 0
    private(set) var shouldStop = false

    init(limit: Int, policy: ArchiveResourcePolicy.Listing) throws {
        guard limit >= 0 else {
            throw QuickLookArchiveListingError.resourceLimitExceeded
        }
        self.limit = min(limit, max(0, policy.listingHardCap))
        self.policy = policy
    }

    mutating func append(_ entry: ArchiveEntry) throws {
        guard !shouldStop else { return }
        if entries.count == limit {
            shouldStop = true
            return
        }

        let path = entry.pathname
        let pathBytes = path.lengthOfBytes(using: .utf8)
        try Self.validate(path: path, byteCount: pathBytes, policy: policy)
        guard entry.size >= 0 else {
            throw QuickLookArchiveListingError.resourceLimitExceeded
        }
        guard pathBytes <= policy.totalPathByteCap,
              totalPathBytes <= policy.totalPathByteCap - pathBytes else {
            throw QuickLookArchiveListingError.resourceLimitExceeded
        }
        totalPathBytes += pathBytes
        entries.append(XZIPCore.ArchiveEntry(
            path: path,
            uncompressedSize: UInt64(entry.size),
            compressedSize: 0,
            modificationDate: entry.modificationDate,
            isDirectory: entry.fileType == .directory,
            isEncrypted: false
        ))
    }

    var result: ArchiveListingResult {
        ArchiveListingResult(entries: entries, truncated: shouldStop)
    }

    private static func validate(
        path: String,
        byteCount: Int,
        policy: ArchiveResourcePolicy.Listing
    ) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              byteCount <= policy.maximumPathByteCount else {
            throw QuickLookArchiveListingError.invalidEntryPath
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else {
            throw QuickLookArchiveListingError.invalidEntryPath
        }
        guard components.count <= policy.maximumPathDepth else {
            throw QuickLookArchiveListingError.resourceLimitExceeded
        }
    }
}
