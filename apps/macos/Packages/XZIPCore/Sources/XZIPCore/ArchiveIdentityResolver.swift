import CryptoKit
import Darwin
import Foundation
import XZIPDomain

protocol FileSystemIdentityReading: Sendable {
    func stableIdentity(for url: URL) throws -> FileSystemIdentity?
}


protocol FileStatusIdentityReading: FileSystemIdentityReading {
    func stableIdentity(from info: stat) -> FileSystemIdentity?
}

struct DarwinFileSystemIdentityReader: FileStatusIdentityReading {
    func stableIdentity(for url: URL) throws -> FileSystemIdentity? {
        stableIdentity(from: try fileStatus(for: url))
    }

    func stableIdentity(from info: stat) -> FileSystemIdentity? {
        guard info.st_dev != 0, info.st_ino != 0 else {
            return nil
        }

        return .stable(
            volumeIdentifier: volumeIdentifierBitPattern(for: info.st_dev),
            fileIdentifier: UInt64(info.st_ino),
            generation: info.st_gen == 0 ? nil : UInt64(info.st_gen)
        )
    }
}

protocol ArchiveIncarnationTokenProviding: Sendable {
    func nextToken() -> ArchiveIncarnationToken
}

struct UUIDArchiveIncarnationTokenProvider: ArchiveIncarnationTokenProviding {
    func nextToken() -> ArchiveIncarnationToken {
        ArchiveIncarnationToken()
    }
}

public struct ArchiveIdentityResolver: ArchiveIdentityResolving, Sendable {
    private let identityReader: any FileSystemIdentityReading
    private let incarnationTokenProvider: any ArchiveIncarnationTokenProviding
    private let fingerprintReadChunkSize: Int
    private let fingerprintChunkObserver: (@Sendable (Int) throws -> Void)?

    public init(fingerprintByteLimit: Int = 64 * 1_024) {
        self.init(
            identityReader: DarwinFileSystemIdentityReader(),
            incarnationTokenProvider: UUIDArchiveIncarnationTokenProvider(),
            fingerprintByteLimit: fingerprintByteLimit,
            fingerprintChunkObserver: nil
        )
    }

    init(
        identityReader: any FileSystemIdentityReading,
        incarnationTokenProvider: any ArchiveIncarnationTokenProviding,
        fingerprintByteLimit: Int = 64 * 1_024,
        fingerprintChunkObserver: (@Sendable (Int) throws -> Void)? = nil
    ) {
        self.identityReader = identityReader
        self.incarnationTokenProvider = incarnationTokenProvider
        fingerprintReadChunkSize = fingerprintByteLimit > 0
            ? fingerprintByteLimit
            : 64 * 1_024
        self.fingerprintChunkObserver = fingerprintChunkObserver
    }

    public func resolve(_ url: URL) throws -> ResolvedArchive {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let info = try fileStatus(for: handle.fileDescriptor, path: url.path)
        let stableIdentity: FileSystemIdentity?
        if let fileStatusReader = identityReader as? any FileStatusIdentityReading {
            stableIdentity = fileStatusReader.stableIdentity(from: info)
        } else {
            stableIdentity = try identityReader.stableIdentity(for: url)
        }

        let identity = stableIdentity ?? .canonicalPath(
            path: url.resolvingSymlinksInPath().standardizedFileURL.path,
            incarnation: incarnationTokenProvider.nextToken()
        )
        let archiveID = ArchiveID(identity: identity)
        guard info.st_size >= 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }

        let fileSize = UInt64(info.st_size)
        let modificationDate = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        let fingerprint = try fullContentFingerprint(from: handle, fileSize: fileSize)
        let finalInfo = try fileStatus(for: handle.fileDescriptor, path: url.path)
        guard info.st_dev == finalInfo.st_dev,
              info.st_ino == finalInfo.st_ino,
              info.st_size == finalInfo.st_size,
              info.st_mtimespec.tv_sec == finalInfo.st_mtimespec.tv_sec,
              info.st_mtimespec.tv_nsec == finalInfo.st_mtimespec.tv_nsec,
              info.st_ctimespec.tv_sec == finalInfo.st_ctimespec.tv_sec,
              info.st_ctimespec.tv_nsec == finalInfo.st_ctimespec.tv_nsec
        else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        let locator = ArchiveLocator(archiveID: archiveID, url: url)
        let revision = ArchiveRevision(
            archiveID: archiveID,
            fileSize: fileSize,
            contentModificationDate: modificationDate,
            boundedContentFingerprint: fingerprint
        )
        return ResolvedArchive(locator: locator, revision: revision)
    }

    public func stableVolumeIdentifier(for url: URL) throws -> UInt64 {
        var candidate = url.standardizedFileURL
        while true {
            do {
                let info = try fileStatus(for: candidate)
                guard info.st_dev != 0 else {
                    throw CocoaError(
                        .fileReadUnknown,
                        userInfo: [NSFilePathErrorKey: candidate.path]
                    )
                }
                return volumeIdentifierBitPattern(for: info.st_dev)
            } catch {
                let cocoaError = error as NSError
                let isMissingPath = cocoaError.domain == NSPOSIXErrorDomain
                    && (cocoaError.code == Int(ENOENT) || cocoaError.code == Int(ENOTDIR))
                let parent = candidate.deletingLastPathComponent()
                guard isMissingPath, parent.path != candidate.path else {
                    throw error
                }
                candidate = parent
            }
        }
    }

    private func fullContentFingerprint(
        from handle: FileHandle,
        fileSize: UInt64
    ) throws -> Data {
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        var remaining = fileSize
        var chunkIndex = 0
        while remaining > 0 {
            let requested = Int(min(UInt64(fingerprintReadChunkSize), remaining))
            guard let chunk = try handle.read(upToCount: requested),
                  !chunk.isEmpty
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            hasher.update(data: chunk)
            try fingerprintChunkObserver?(chunkIndex)
            chunkIndex += 1
            remaining -= UInt64(chunk.count)
        }
        return Data(hasher.finalize())
    }
}

func volumeIdentifierBitPattern(for device: dev_t) -> UInt64 {
    UInt64(UInt32(bitPattern: device))
}

private func fileStatus(for descriptor: Int32, path: String) throws -> stat {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
        let errorCode = errno
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errorCode),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
    return info
}

private func fileStatus(for url: URL) throws -> stat {
    var info = stat()
    let result = url.path.withCString { path in
        fstatat(AT_FDCWD, path, &info, 0)
    }
    guard result == 0 else {
        let errorCode = errno
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errorCode),
            userInfo: [NSFilePathErrorKey: url.path]
        )
    }
    return info
}
