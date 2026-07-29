import Foundation

public struct ArchiveResourcePolicy: Hashable, Codable, Sendable {
    public struct Listing: Hashable, Codable, Sendable {
        public let browserEntryCap: Int
        public let listingHardCap: Int
        public let totalPathByteCap: Int
        public let maximumPathByteCount: Int
        public let maximumPathDepth: Int

        public init(
            browserEntryCap: Int,
            listingHardCap: Int,
            totalPathByteCap: Int,
            maximumPathByteCount: Int,
            maximumPathDepth: Int
        ) {
            self.browserEntryCap = browserEntryCap
            self.listingHardCap = listingHardCap
            self.totalPathByteCap = totalPathByteCap
            self.maximumPathByteCount = maximumPathByteCount
            self.maximumPathDepth = maximumPathDepth
        }
    }

    public struct Output: Hashable, Codable, Sendable {
        public let advertisedOutputByteCap: UInt64
        public let advertisedDictionaryByteCap: UInt64
        public let stagingByteCap: UInt64

        public init(
            advertisedOutputByteCap: UInt64,
            advertisedDictionaryByteCap: UInt64,
            stagingByteCap: UInt64
        ) {
            self.advertisedOutputByteCap = advertisedOutputByteCap
            self.advertisedDictionaryByteCap = advertisedDictionaryByteCap
            self.stagingByteCap = stagingByteCap
        }
    }

    public struct Process: Hashable, Codable, Sendable {
        public let stdoutBufferByteCap: Int
        public let stderrTailByteCap: Int
        public let rawChunkByteCap: Int
        public let progressEventBufferCount: Int
        public let progressInterval: TimeInterval
        public let terminationGracePeriod: TimeInterval

        public init(
            stdoutBufferByteCap: Int,
            stderrTailByteCap: Int,
            rawChunkByteCap: Int,
            progressEventBufferCount: Int,
            progressInterval: TimeInterval,
            terminationGracePeriod: TimeInterval
        ) {
            self.stdoutBufferByteCap = stdoutBufferByteCap
            self.stderrTailByteCap = stderrTailByteCap
            self.rawChunkByteCap = rawChunkByteCap
            self.progressEventBufferCount = progressEventBufferCount
            self.progressInterval = progressInterval
            self.terminationGracePeriod = terminationGracePeriod
        }
    }

    public struct Cache: Hashable, Codable, Sendable {
        public let weightBudget: Int

        public init(weightBudget: Int) {
            self.weightBudget = weightBudget
        }
    }

    public struct Split: Hashable, Codable, Sendable {
        public let maximumSuffixWidth: Int
        public let maximumPartIndex: Int
        public let maximumPartCount: Int

        public init(
            maximumSuffixWidth: Int,
            maximumPartIndex: Int,
            maximumPartCount: Int
        ) {
            self.maximumSuffixWidth = maximumSuffixWidth
            self.maximumPartIndex = maximumPartIndex
            self.maximumPartCount = maximumPartCount
        }
    }

    public struct Command: Hashable, Codable, Sendable {
        public let maximumPathCount: Int
        public let maximumRequestBytes: Int
        public let maximumPendingRequestCount: Int
        public let maximumPullCount: Int
        public let replayWindow: TimeInterval
        public let longPollTimeout: TimeInterval

        public init(
            maximumPathCount: Int,
            maximumRequestBytes: Int,
            maximumPendingRequestCount: Int,
            maximumPullCount: Int,
            replayWindow: TimeInterval,
            longPollTimeout: TimeInterval
        ) {
            self.maximumPathCount = maximumPathCount
            self.maximumRequestBytes = maximumRequestBytes
            self.maximumPendingRequestCount = maximumPendingRequestCount
            self.maximumPullCount = maximumPullCount
            self.replayWindow = replayWindow
            self.longPollTimeout = longPollTimeout
        }
    }

    public struct Journal: Hashable, Codable, Sendable {
        public let maximumJournalBytes: Int
        public let retention: TimeInterval
        public let maximumRecoveryCountPerLaunch: Int
        public let maximumPruneCountPerPass: Int

        public init(
            maximumJournalBytes: Int,
            retention: TimeInterval,
            maximumRecoveryCountPerLaunch: Int,
            maximumPruneCountPerPass: Int
        ) {
            self.maximumJournalBytes = maximumJournalBytes
            self.retention = retention
            self.maximumRecoveryCountPerLaunch = maximumRecoveryCountPerLaunch
            self.maximumPruneCountPerPass = maximumPruneCountPerPass
        }
    }

    public struct Scheduling: Hashable, Codable, Sendable {
        public let globalProcessLimit: Int
        public let metadataProcessLimit: Int
        public let heavyIOPerVolumeLimit: Int

        public init(
            globalProcessLimit: Int,
            metadataProcessLimit: Int,
            heavyIOPerVolumeLimit: Int
        ) {
            self.globalProcessLimit = globalProcessLimit
            self.metadataProcessLimit = metadataProcessLimit
            self.heavyIOPerVolumeLimit = heavyIOPerVolumeLimit
        }
    }

    public let listing: Listing
    public let output: Output
    public let process: Process
    public let cache: Cache
    public let split: Split
    public let command: Command
    public let journal: Journal
    public let scheduling: Scheduling

    public init(
        listing: Listing,
        output: Output,
        process: Process,
        cache: Cache,
        split: Split,
        command: Command,
        journal: Journal,
        scheduling: Scheduling
    ) {
        self.listing = listing
        self.output = output
        self.process = process
        self.cache = cache
        self.split = split
        self.command = command
        self.journal = journal
        self.scheduling = scheduling
    }

    public static let production = ArchiveResourcePolicy(
        listing: Listing(
            browserEntryCap: 100_000,
            listingHardCap: 1_000_000,
            totalPathByteCap: 64 * 1_024 * 1_024,
            maximumPathByteCount: 32 * 1_024,
            maximumPathDepth: 256
        ),
        output: Output(
            advertisedOutputByteCap: 1_024 * 1_024 * 1_024 * 1_024,
            advertisedDictionaryByteCap: 4 * 1_024 * 1_024 * 1_024,
            stagingByteCap: 1_024 * 1_024 * 1_024 * 1_024
        ),
        process: Process(
            stdoutBufferByteCap: 4 * 1_024 * 1_024,
            stderrTailByteCap: 1 * 1_024 * 1_024,
            rawChunkByteCap: 256 * 1_024,
            progressEventBufferCount: 1,
            progressInterval: 0.1,
            terminationGracePeriod: 2
        ),
        cache: Cache(weightBudget: 128 * 1_024 * 1_024),
        split: Split(
            maximumSuffixWidth: 6,
            maximumPartIndex: 999_999,
            maximumPartCount: 10_000
        ),
        command: Command(
            maximumPathCount: 256,
            maximumRequestBytes: 1 * 1_024 * 1_024,
            maximumPendingRequestCount: 256,
            maximumPullCount: 32,
            replayWindow: 10 * 60,
            longPollTimeout: 20
        ),
        journal: Journal(
            maximumJournalBytes: 16 * 1_024 * 1_024,
            retention: 7 * 24 * 60 * 60,
            maximumRecoveryCountPerLaunch: 32,
            maximumPruneCountPerPass: 64
        ),
        scheduling: Scheduling(
            globalProcessLimit: 4,
            metadataProcessLimit: 2,
            heavyIOPerVolumeLimit: 1
        )
    )

    public func replacingForTests(
        browserEntryCap: Int? = nil,
        listingHardCap: Int? = nil,
        totalPathByteCap: Int? = nil,
        maximumPathByteCount: Int? = nil,
        maximumPathDepth: Int? = nil,
        cacheWeightBudget: Int? = nil,
        splitMaximumSuffixWidth: Int? = nil,
        splitMaximumPartIndex: Int? = nil,
        splitMaximumPartCount: Int? = nil,
        commandMaximumPathCount: Int? = nil,
        commandMaximumRequestBytes: Int? = nil,
        commandMaximumPendingRequestCount: Int? = nil,
        commandMaximumPullCount: Int? = nil,
        commandReplayWindow: TimeInterval? = nil,
        commandLongPollTimeout: TimeInterval? = nil,
        stagingByteCap: UInt64? = nil
    ) -> ArchiveResourcePolicy {
        ArchiveResourcePolicy(
            listing: Listing(
                browserEntryCap: browserEntryCap ?? listing.browserEntryCap,
                listingHardCap: listingHardCap ?? listing.listingHardCap,
                totalPathByteCap: totalPathByteCap ?? listing.totalPathByteCap,
                maximumPathByteCount: maximumPathByteCount
                    ?? listing.maximumPathByteCount,
                maximumPathDepth: maximumPathDepth ?? listing.maximumPathDepth
            ),
            output: Output(
                advertisedOutputByteCap: output.advertisedOutputByteCap,
                advertisedDictionaryByteCap: output.advertisedDictionaryByteCap,
                stagingByteCap: stagingByteCap ?? output.stagingByteCap
            ),
            process: process,
            cache: Cache(weightBudget: cacheWeightBudget ?? cache.weightBudget),
            split: Split(
                maximumSuffixWidth: splitMaximumSuffixWidth ?? split.maximumSuffixWidth,
                maximumPartIndex: splitMaximumPartIndex ?? split.maximumPartIndex,
                maximumPartCount: splitMaximumPartCount ?? split.maximumPartCount
            ),
            command: Command(
                maximumPathCount: commandMaximumPathCount ?? command.maximumPathCount,
                maximumRequestBytes: commandMaximumRequestBytes ?? command.maximumRequestBytes,
                maximumPendingRequestCount: commandMaximumPendingRequestCount
                    ?? command.maximumPendingRequestCount,
                maximumPullCount: commandMaximumPullCount ?? command.maximumPullCount,
                replayWindow: commandReplayWindow ?? command.replayWindow,
                longPollTimeout: commandLongPollTimeout ?? command.longPollTimeout
            ),
            journal: journal,
            scheduling: scheduling
        )
    }
}

public enum StagingByteAccounting {
    public static func adding(
        current: UInt64,
        logical: UInt64,
        allocated: UInt64,
        limit: UInt64
    ) throws -> UInt64 {
        let charge = max(logical, allocated)
        let (next, overflow) = current.addingReportingOverflow(charge)
        guard !overflow, next <= limit else {
            throw ArchiveFailure.resourceLimitExceeded(
                kind: .stagingBytes,
                limit: limit,
                observed: overflow ? .max : next
            )
        }
        return next
    }
}
