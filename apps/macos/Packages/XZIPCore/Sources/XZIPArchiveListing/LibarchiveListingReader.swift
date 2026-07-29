import Archive
import CArchive
import Foundation
import XZIPArchiveListingCLocale
import XZIPCore
import XZIPDomain

public struct LibarchiveListingReader: ArchiveListingReading, Sendable {
    private static let detectionHeaderLength = 32_774

    private let policy: ArchiveResourcePolicy.Listing
    private let beforeReading: @Sendable () async throws -> Void

    public init(
        policy: ArchiveResourcePolicy.Listing = ArchiveResourcePolicy.production.listing
    ) {
        self.policy = policy
        self.beforeReading = {}
    }

    init(
        policy: ArchiveResourcePolicy.Listing = ArchiveResourcePolicy.production.listing,
        beforeReading: @escaping @Sendable () async throws -> Void
    ) {
        self.policy = policy
        self.beforeReading = beforeReading
    }

    public func list(archive: URL, limit: Int) async throws -> ArchiveListingResult {
        let policy = self.policy
        let beforeReading = self.beforeReading
        let work = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                try await beforeReading()
                try Task.checkCancellation()
                guard let format = try Self.detectFormat(fileAt: archive),
                      [.zip, .sevenZip, .tar, .rar].contains(format) else {
                    throw QuickLookArchiveListingError.unsupportedFormat
                }

                var accumulator = try ListingAccumulator(limit: limit, policy: policy)
                guard let localeScope = XZIPBeginUTF8Locale() else {
                    throw LocaleScopeError.unavailable
                }
                defer { XZIPEndUTF8Locale(localeScope) }

                return try Self.readHeaders(
                    from: archive,
                    accumulator: &accumulator
                )
            } catch {
                throw Self.map(error)
            }
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    static func isHeaderEncryptionError(code: Int32, message: String) -> Bool {
        code == -1
            && message.lowercased()
                == "the archive header is encrypted, but currently not supported"
    }

    private static func readHeaders(
        from url: URL,
        accumulator: inout ListingAccumulator
    ) throws -> ArchiveListingResult {
        guard let archive = archive_read_new() else {
            throw LibarchiveReadError(
                code: 0,
                message: "Failed to create archive reader"
            )
        }
        defer { archive_read_free(archive) }

        try registerAllowedReaders(on: archive)
        guard archive_read_open_filename(archive, url.path, 10_240) == ARCHIVE_OK else {
            throw readError(from: archive)
        }
        guard archive_filter_code(archive, 0) == ARCHIVE_FILTER_NONE else {
            throw LibarchiveReadError(code: 0, message: "Unsupported archive filter")
        }

        while true {
            try Task.checkCancellation()
            var rawEntry: OpaquePointer?
            let status = archive_read_next_header(archive, &rawEntry)
            if status == ARCHIVE_EOF {
                try validateDetectedArchive(archive)
                return accumulator.result
            }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
                throw readError(from: archive)
            }
            try validateDetectedArchive(archive)
            guard let rawEntry,
                  let rawPath = archive_entry_pathname(rawEntry) else {
                continue
            }

            let entry = ArchiveEntry(
                pathname: String(cString: rawPath),
                size: archive_entry_size(rawEntry),
                fileType: UInt32(archive_entry_filetype(rawEntry)) == 0o040000
                    ? .directory
                    : .regular,
                modificationDate: Date(
                    timeIntervalSince1970: TimeInterval(archive_entry_mtime(rawEntry))
                )
            )
            try Task.checkCancellation()
            try accumulator.append(entry)
            if accumulator.shouldStop {
                return accumulator.result
            }
        }
    }

    private static func registerAllowedReaders(on archive: OpaquePointer) throws {
        let statuses = [
            archive_read_support_filter_none(archive),
            archive_read_support_format_zip(archive),
            archive_read_support_format_7zip(archive),
            archive_read_support_format_tar(archive),
            archive_read_support_format_rar(archive),
            archive_read_support_format_rar5(archive),
        ]
        guard statuses.allSatisfy({ $0 == ARCHIVE_OK }) else {
            throw readError(from: archive)
        }
    }

    private static func validateDetectedArchive(_ archive: OpaquePointer) throws {
        guard archive_filter_code(archive, 0) == ARCHIVE_FILTER_NONE else {
            throw LibarchiveReadError(code: 0, message: "Unsupported archive filter")
        }

        let format = archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK
        let allowedFormats = [
            ARCHIVE_FORMAT_ZIP,
            ARCHIVE_FORMAT_7ZIP,
            ARCHIVE_FORMAT_TAR,
            ARCHIVE_FORMAT_RAR,
            ARCHIVE_FORMAT_RAR_V5,
        ]
        guard allowedFormats.contains(format) else {
            throw LibarchiveReadError(code: 0, message: "Unsupported archive format")
        }
    }

    private static func readError(from archive: OpaquePointer) -> LibarchiveReadError {
        let message = archive_error_string(archive).map(String.init(cString:))
            ?? "Unknown libarchive error"
        return LibarchiveReadError(code: archive_errno(archive), message: message)
    }

    private static func detectFormat(fileAt url: URL) throws -> XZIPCore.ArchiveFormat? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: detectionHeaderLength) ?? Data()
        return ArchiveFormatDetector.detect(headerBytes: [UInt8](data))
    }

    private static func map(_ error: Error) -> Error {
        if error is CancellationError {
            return error
        }
        if let error = error as? QuickLookArchiveListingError {
            return error
        }
        if let error = error as? LibarchiveReadError,
           isHeaderEncryptionError(code: error.code, message: error.message) {
            return QuickLookArchiveListingError.encrypted
        }
        return QuickLookArchiveListingError.unreadableArchive
    }
}

private enum LocaleScopeError: Error {
    case unavailable
}

private struct LibarchiveReadError: Error {
    let code: Int32
    let message: String
}
