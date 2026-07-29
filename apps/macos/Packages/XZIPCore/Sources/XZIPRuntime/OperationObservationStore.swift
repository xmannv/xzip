import Foundation
import XZIPCore
import XZIPDomain

public struct ExtractionResult: Equatable, Sendable {
    public let transactionID: TransactionID
    public let publishedURLs: [URL]
    public let skippedPaths: [String]

    public init(
        transactionID: TransactionID,
        publishedURLs: [URL],
        skippedPaths: [String]
    ) {
        self.transactionID = transactionID
        self.publishedURLs = publishedURLs
        self.skippedPaths = skippedPaths
    }
}

public struct CompressionResult: Equatable, Sendable {
    public let finalURLs: [URL]

    public init(finalURLs: [URL]) {
        self.finalURLs = finalURLs
    }
}

public enum OperationProgressEvent: Sendable {
    case archive(ArchiveProgress)
    case repackStep(RepackStep)
}

public enum OperationResult: Sendable {
    case integrityTest(Bool)
    case archiveComment(String)
    case extraction(ExtractionResult)
    case compression(CompressionResult)
}

public protocol ArchiveRuntimeObserving: Sendable {
    func progress(
        for operationID: OperationID
    ) async -> AsyncStream<OperationProgressEvent>
    func result(for operationID: OperationID) async -> OperationResult?
    func state(for operationID: OperationID) async -> OperationState?
    func cancelOperation(_ operationID: OperationID) async
}

actor OperationObservationStore {
    struct Policy: Sendable {
        let maximumRecordCount: Int

        init(maximumRecordCount: Int) {
            self.maximumRecordCount = max(0, maximumRecordCount)
        }
    }

    enum DebugEvent: Equatable, Sendable {
        case subscriberRegistered(OperationID)
        case subscriberRemoved(OperationID)
        case recordRemoved(OperationID)
    }

    private struct Record {
        var state: OperationState?
        var result: OperationResult?
        var subscribers: [UUID: AsyncStream<OperationProgressEvent>.Continuation] = [:]
        var terminalSequence: UInt64?
    }

    private let policy: Policy
    private let debugProbe: (@Sendable (DebugEvent) -> Void)?
    private var records: [OperationID: Record] = [:]
    private var nextTerminalSequence: UInt64 = 0

    init(policy: Policy) {
        self.policy = policy
        debugProbe = nil
    }

    init(
        policy: Policy,
        debugProbe: (@Sendable (DebugEvent) -> Void)?
    ) {
        self.policy = policy
        self.debugProbe = debugProbe
    }

    func register(_ operationID: OperationID) -> AsyncStream<OperationProgressEvent> {
        let subscriberID = UUID()
        let pair = AsyncStream<OperationProgressEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSubscriber(
                    subscriberID,
                    operationID: operationID
                )
            }
        }

        var record = records[operationID] ?? Record()
        if isTerminal(record.state) {
            pair.continuation.finish()
        } else {
            record.subscribers[subscriberID] = pair.continuation
            records[operationID] = record
            debugProbe?(.subscriberRegistered(operationID))
        }
        return pair.stream
    }

    func beginOperation(_ operationID: OperationID) -> Bool {
        var record = records[operationID] ?? Record()
        guard record.state == nil,
              record.result == nil,
              record.terminalSequence == nil else {
            return false
        }
        record.state = .queued
        records[operationID] = record
        return true
    }

    func setState(_ state: OperationState, for operationID: OperationID) {
        var record = records[operationID] ?? Record()
        guard !isTerminal(record.state) else { return }
        record.state = state
        records[operationID] = record
    }

    func transitionToStoppingIfNeeded(_ operationID: OperationID) -> Bool {
        guard var record = records[operationID],
              record.state == .running || record.state == .waitingForCredential else {
            return false
        }
        record.state = .stopping
        records[operationID] = record
        return true
    }

    func publishProgress(
        _ event: OperationProgressEvent,
        for operationID: OperationID
    ) {
        guard let record = records[operationID], !isTerminal(record.state) else {
            return
        }
        for continuation in record.subscribers.values {
            continuation.yield(event)
        }
    }

    func publishResult(_ result: OperationResult, for operationID: OperationID) {
        var record = records[operationID] ?? Record()
        guard !isTerminal(record.state) else { return }
        record.result = result
        records[operationID] = record
    }

    func result(for operationID: OperationID) -> OperationResult? {
        records[operationID]?.result
    }

    func state(for operationID: OperationID) -> OperationState? {
        records[operationID]?.state
    }

    func finishTerminal(
        _ operationID: OperationID,
        state: OperationState,
        result: OperationResult? = nil
    ) {
        guard isTerminal(state) else {
            setState(state, for: operationID)
            return
        }

        var record = records[operationID] ?? Record()
        guard !isTerminal(record.state) else { return }
        record.state = state
        if state == .completed {
            if let result {
                record.result = result
            }
        } else {
            record.result = nil
        }
        record.terminalSequence = nextTerminalSequence
        nextTerminalSequence &+= 1
        let continuations = Array(record.subscribers.values)
        record.subscribers.removeAll()
        records[operationID] = record

        for continuation in continuations {
            continuation.finish()
        }
        evictTerminalRecordsIfNeeded()
    }

    func removeSubscriber(_ subscriberID: UUID, operationID: OperationID) {
        guard var record = records[operationID],
              let continuation = record.subscribers.removeValue(forKey: subscriberID) else {
            return
        }
        continuation.finish()
        debugProbe?(.subscriberRemoved(operationID))

        if record.subscribers.isEmpty,
           record.state == nil,
           record.result == nil,
           record.terminalSequence == nil {
            records.removeValue(forKey: operationID)
            debugProbe?(.recordRemoved(operationID))
        } else {
            records[operationID] = record
        }
    }

    func remove(_ operationID: OperationID) {
        guard let record = records.removeValue(forKey: operationID) else { return }
        for continuation in record.subscribers.values {
            continuation.finish()
        }
        debugProbe?(.recordRemoved(operationID))
    }

    func removeAll() {
        let removed = records
        records.removeAll()
        for (operationID, record) in removed {
            for continuation in record.subscribers.values {
                continuation.finish()
            }
            debugProbe?(.recordRemoved(operationID))
        }
    }

    func debugRecordCount() -> Int {
        records.count
    }

    func debugSubscriberCount(for operationID: OperationID) -> Int {
        records[operationID]?.subscribers.count ?? 0
    }

    private func isTerminal(_ state: OperationState?) -> Bool {
        switch state {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .running, .waitingForCredential, .stopping, nil:
            return false
        }
    }

    private func evictTerminalRecordsIfNeeded() {
        while records.count > policy.maximumRecordCount {
            guard let oldest = records.min(by: { lhs, rhs in
                terminalSequence(lhs.value) < terminalSequence(rhs.value)
            }), oldest.value.terminalSequence != nil else {
                return
            }
            remove(oldest.key)
        }
    }

    private func terminalSequence(_ record: Record) -> UInt64 {
        record.terminalSequence ?? UInt64.max
    }
}
