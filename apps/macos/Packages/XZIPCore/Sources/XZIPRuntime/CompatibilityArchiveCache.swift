import Foundation
import XZIPCore
import XZIPDomain

actor CompatibilityArchiveCache {
    struct CacheKey: Hashable, Sendable {
        let archiveID: ArchiveID
        let revision: ArchiveRevision
    }

    struct LoadToken: Hashable, Sendable {
        fileprivate let key: CacheKey
        fileprivate let mutationGeneration: UInt64
        fileprivate let loadEpoch: UInt64
        fileprivate let loadSequence: UInt64
    }

    private struct ListingValue {
        let entries: [ArchiveEntry]
        let weight: Int
        var accessSequence: UInt64
    }

    private struct FormatValue {
        let format: ArchiveFormat
        var accessSequence: UInt64
    }

    private let listingCapacity: Int
    private let formatCapacity: Int
    private let listingWeightBudget: Int
    private let metadataCapacity: Int
    private let initialMutationGeneration: UInt64

    private var listings: [CacheKey: ListingValue] = [:]
    private var formats: [CacheKey: FormatValue] = [:]
    private var activeLoads: [UInt64: LoadToken] = [:]
    private var latestLoadSequence: [CacheKey: UInt64] = [:]
    private var mutationGenerations: [ArchiveID: UInt64] = [:]
    private var totalListingWeight = 0
    private var loadEpoch: UInt64
    private var loadSequence: UInt64
    private var accessSequence: UInt64
    private var loadIdentifiersExhausted = false

    init(
        listingCapacity: Int = 32,
        formatCapacity: Int = 64,
        listingWeightBudget: Int = ArchiveResourcePolicy.production.cache.weightBudget,
        metadataCapacity: Int = 128,
        initialLoadSequence: UInt64 = 0,
        initialLoadEpoch: UInt64 = 0,
        initialAccessSequence: UInt64 = 0,
        initialMutationGeneration: UInt64 = 0
    ) {
        self.listingCapacity = max(0, listingCapacity)
        self.formatCapacity = max(0, formatCapacity)
        self.listingWeightBudget = max(0, listingWeightBudget)
        self.metadataCapacity = max(0, metadataCapacity)
        self.initialMutationGeneration = initialMutationGeneration
        self.loadEpoch = initialLoadEpoch
        self.loadSequence = initialLoadSequence
        self.accessSequence = initialAccessSequence
    }

    func cachedListing(for key: CacheKey) -> [ArchiveEntry]? {
        guard var value = listings[key] else { return nil }
        value.accessSequence = nextAccessSequence()
        listings[key] = value
        return value.entries
    }

    func cachedFormat(for key: CacheKey) -> ArchiveFormat? {
        guard var value = formats[key] else { return nil }
        value.accessSequence = nextAccessSequence()
        formats[key] = value
        return value.format
    }

    func beginLoad(for key: CacheKey) -> LoadToken {
        let generation = mutationGenerations[key.archiveID]
            ?? initialMutationGeneration
        guard let identifier = nextLoadIdentifier() else {
            return LoadToken(
                key: key,
                mutationGeneration: generation,
                loadEpoch: loadEpoch,
                loadSequence: loadSequence
            )
        }
        let token = LoadToken(
            key: key,
            mutationGeneration: generation,
            loadEpoch: identifier.epoch,
            loadSequence: identifier.sequence
        )
        activeLoads[identifier.sequence] = token
        latestLoadSequence[key] = identifier.sequence
        mutationGenerations[key.archiveID] = generation
        trimLoadMetadata()
        return token
    }

    func finishLoad(_ token: LoadToken) {
        retire(token)
    }

    func storeListing(_ entries: [ArchiveEntry], token: LoadToken) {
        guard accepts(token) else {
            retire(token)
            return
        }
        let weight = listingWeight(entries)
        guard listingCapacity > 0, weight <= listingWeightBudget else { return }

        if let oldValue = listings.removeValue(forKey: token.key) {
            totalListingWeight -= oldValue.weight
        }
        while listings.count >= listingCapacity
            || totalListingWeight > listingWeightBudget - weight {
            guard let key = oldestListingKey() else { break }
            removeListing(for: key)
        }
        guard listings.count < listingCapacity,
              totalListingWeight <= listingWeightBudget - weight else {
            return
        }

        listings[token.key] = ListingValue(
            entries: entries,
            weight: weight,
            accessSequence: nextAccessSequence()
        )
        totalListingWeight += weight
    }

    func storeFormat(_ format: ArchiveFormat, token: LoadToken) {
        guard accepts(token) else {
            retire(token)
            return
        }
        guard formatCapacity > 0 else { return }
        if formats[token.key] == nil, formats.count >= formatCapacity,
           let key = oldestFormatKey() {
            removeFormat(for: key)
        }
        formats[token.key] = FormatValue(
            format: format,
            accessSequence: nextAccessSequence()
        )
    }

    func invalidate(archiveID: ArchiveID) {
        let generation = mutationGenerations[archiveID]
            ?? initialMutationGeneration
        let (nextGeneration, overflow) = generation.addingReportingOverflow(1)
        retireLoads(for: archiveID)
        mutationGenerations[archiveID] = overflow ? 0 : nextGeneration

        let listingKeys = listings.keys.filter { $0.archiveID == archiveID }
        for key in listingKeys {
            removeListing(for: key)
        }
        let formatKeys = formats.keys.filter { $0.archiveID == archiveID }
        for key in formatKeys {
            removeFormat(for: key)
        }
        latestLoadSequence = latestLoadSequence.filter {
            $0.key.archiveID != archiveID
        }
        cleanupMutationGeneration(for: archiveID)
    }

    func activeLoadCountForTesting() -> Int {
        activeLoads.count
    }

    func latestLoadCountForTesting() -> Int {
        latestLoadSequence.count
    }

    func mutationGenerationCountForTesting() -> Int {
        mutationGenerations.count
    }

    private func accepts(_ token: LoadToken) -> Bool {
        activeLoads[token.loadSequence] == token
            && mutationGenerations[token.key.archiveID] == token.mutationGeneration
            && latestLoadSequence[token.key] == token.loadSequence
    }

    private func retire(_ token: LoadToken) {
        guard activeLoads[token.loadSequence] == token else { return }
        activeLoads.removeValue(forKey: token.loadSequence)
        if latestLoadSequence[token.key] == token.loadSequence {
            latestLoadSequence.removeValue(forKey: token.key)
        }
        cleanupMutationGeneration(for: token.key.archiveID)
    }

    private func retireLoads(for archiveID: ArchiveID) {
        let tokens = activeLoads.values.filter {
            $0.key.archiveID == archiveID
        }
        for token in tokens {
            retire(token)
        }
    }

    private func trimLoadMetadata() {
        while activeLoads.count > metadataCapacity,
              let oldestSequence = activeLoads.keys.min(),
              let token = activeLoads[oldestSequence] {
            retire(token)
        }
    }

    private func cleanupMutationGeneration(for archiveID: ArchiveID) {
        guard !activeLoads.values.contains(where: {
            $0.key.archiveID == archiveID
        }) else { return }
        mutationGenerations.removeValue(forKey: archiveID)
    }

    private func cleanupLoadMetadata(for key: CacheKey) {
        guard !activeLoads.values.contains(where: { $0.key == key }) else {
            return
        }
        latestLoadSequence.removeValue(forKey: key)
        cleanupMutationGeneration(for: key.archiveID)
    }

    private func listingWeight(_ entries: [ArchiveEntry]) -> Int {
        entries.reduce(into: 0) { total, entry in
            let (entryWeight, overflow) = entry.path.utf8.count.addingReportingOverflow(64)
            guard !overflow else {
                total = Int.max
                return
            }
            let (newTotal, totalOverflow) = total.addingReportingOverflow(entryWeight)
            total = totalOverflow ? Int.max : newTotal
        }
    }

    private func oldestListingKey() -> CacheKey? {
        listings.min { lhs, rhs in
            lhs.value.accessSequence < rhs.value.accessSequence
        }?.key
    }

    private func oldestFormatKey() -> CacheKey? {
        formats.min { lhs, rhs in
            lhs.value.accessSequence < rhs.value.accessSequence
        }?.key
    }

    private func removeListing(for key: CacheKey) {
        guard let value = listings.removeValue(forKey: key) else { return }
        totalListingWeight -= value.weight
        if formats[key] == nil {
            cleanupLoadMetadata(for: key)
        }
    }

    private func removeFormat(for key: CacheKey) {
        guard formats.removeValue(forKey: key) != nil else { return }
        if listings[key] == nil {
            cleanupLoadMetadata(for: key)
        }
    }

    private func nextLoadIdentifier() -> (epoch: UInt64, sequence: UInt64)? {
        guard !loadIdentifiersExhausted else { return nil }
        let (next, overflow) = loadSequence.addingReportingOverflow(1)
        if overflow {
            activeLoads.removeAll(keepingCapacity: true)
            latestLoadSequence.removeAll(keepingCapacity: true)
            mutationGenerations.removeAll(keepingCapacity: true)
            let (nextEpoch, epochOverflow) = loadEpoch.addingReportingOverflow(1)
            guard !epochOverflow else {
                loadIdentifiersExhausted = true
                return nil
            }
            loadEpoch = nextEpoch
            loadSequence = 1
            return (nextEpoch, 1)
        }
        loadSequence = next
        return (loadEpoch, next)
    }

    private func nextAccessSequence() -> UInt64 {
        let (next, overflow) = accessSequence.addingReportingOverflow(1)
        if !overflow {
            accessSequence = next
            return next
        }

        renormalizeAccessSequences()
        let (renormalizedNext, secondOverflow) = accessSequence.addingReportingOverflow(1)
        if secondOverflow {
            listings.removeAll(keepingCapacity: true)
            formats.removeAll(keepingCapacity: true)
            totalListingWeight = 0
            accessSequence = 1
            return 1
        }
        accessSequence = renormalizedNext
        return renormalizedNext
    }

    private func renormalizeAccessSequences() {
        let listingKeys = listings.keys.sorted {
            listings[$0]!.accessSequence < listings[$1]!.accessSequence
        }
        for (index, key) in listingKeys.enumerated() {
            listings[key]!.accessSequence = UInt64(index + 1)
        }

        let formatKeys = formats.keys.sorted {
            formats[$0]!.accessSequence < formats[$1]!.accessSequence
        }
        for (index, key) in formatKeys.enumerated() {
            formats[key]!.accessSequence = UInt64(index + 1)
        }
        accessSequence = UInt64(max(listingKeys.count, formatKeys.count))
    }
}
