import XCTest
import XZIPCore
import XZIPDomain
@testable import XZIPRuntime

final class OperationObservationStoreTests: XCTestCase {
    func testSlowProgressSubscriberReceivesNewestBoundedEvent() async {
        let store = OperationObservationStore(policy: .init(maximumRecordCount: 1))
        let operationID = OperationID()
        let stream = await store.register(operationID)
        let firstConsumed = ObservationSignal()
        let resume = ObservationGate()
        let observed = Task { () -> [Double?] in
            var iterator = stream.makeAsyncIterator()
            let first = await iterator.next()
            await firstConsumed.signal()
            await resume.wait()
            let second = await iterator.next()
            return [fraction(first), fraction(second)]
        }

        await store.setState(.running, for: operationID)
        await store.publishProgress(
            .archive(.init(fraction: 0)),
            for: operationID
        )
        await firstConsumed.wait(until: 1)

        for index in 1...1_000 {
            await store.publishProgress(
                .archive(.init(fraction: Double(index))),
                for: operationID
            )
        }
        await resume.open()

        let values = await observed.value
        XCTAssertEqual(values, [0, 1_000])

        await store.finishTerminal(operationID, state: .completed)
        let newerID = OperationID()
        _ = await store.register(newerID)
        await store.finishTerminal(newerID, state: .completed)

        let evictedState = await store.state(for: operationID)
        let retainedState = await store.state(for: newerID)
        XCTAssertNil(evictedState)
        XCTAssertEqual(retainedState, .completed)
    }

    func testSubscriberCancellationDoesNotCancelOperation() async {
        let probe = StoreProbe()
        let store = OperationObservationStore(
            policy: .init(maximumRecordCount: 4),
            debugProbe: probe.record
        )
        let operationID = OperationID()
        let cancelledStream = await store.register(operationID)
        _ = await probe.next()
        let survivingStream = await store.register(operationID)
        _ = await probe.next()
        await store.setState(.running, for: operationID)

        let cancelledConsumer = Task {
            var iterator = cancelledStream.makeAsyncIterator()
            return await iterator.next()
        }
        cancelledConsumer.cancel()
        _ = await cancelledConsumer.value
        let removalEvent = await probe.next()
        XCTAssertEqual(removalEvent, .subscriberRemoved(operationID))
        let subscriberCount = await store.debugSubscriberCount(for: operationID)
        XCTAssertEqual(subscriberCount, 1)

        let survivingConsumer = Task {
            var iterator = survivingStream.makeAsyncIterator()
            return await iterator.next()
        }
        await store.publishProgress(
            .archive(.init(fraction: 0.75)),
            for: operationID
        )

        let event = await survivingConsumer.value
        XCTAssertEqual(fraction(event), 0.75)
        let state = await store.state(for: operationID)
        XCTAssertEqual(state, .running)

        await store.finishTerminal(operationID, state: .completed)
    }

    func testCancelledLastPreRegistrationSubscriberRemovesPlaceholder() async {
        let probe = StoreProbe()
        let store = OperationObservationStore(
            policy: .init(maximumRecordCount: 1),
            debugProbe: probe.record
        )
        let operationID = OperationID()
        let stream = await store.register(operationID)
        let registrationEvent = await probe.next()
        XCTAssertEqual(registrationEvent, .subscriberRegistered(operationID))
        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        consumer.cancel()
        _ = await consumer.value
        let removalEvent = await probe.next()
        XCTAssertEqual(removalEvent, .subscriberRemoved(operationID))
        let recordRemovalEvent = await probe.next()
        XCTAssertEqual(recordRemovalEvent, .recordRemoved(operationID))
        let recordCount = await store.debugRecordCount()
        XCTAssertEqual(recordCount, 0)
    }

    func testBeginOperationAcceptsPreSubscribedPlaceholderAndReservesQueuedState() async {
        let store = OperationObservationStore(policy: .init(maximumRecordCount: 2))
        let operationID = OperationID()
        let stream = await store.register(operationID)

        let began = await store.beginOperation(operationID)

        XCTAssertTrue(began)
        await assertStoreEqual(OperationState.queued) {
            await store.state(for: operationID)
        }
        let subscriberCount = await store.debugSubscriberCount(for: operationID)
        XCTAssertEqual(subscriberCount, 1)
        _ = stream
    }

    func testBeginOperationRejectsRetainedLifecycleWithoutMutatingStateOrResult() async {
        let store = OperationObservationStore(policy: .init(maximumRecordCount: 2))
        let operationID = OperationID()
        await store.setState(.running, for: operationID)
        await store.finishTerminal(
            operationID,
            state: .completed,
            result: .integrityTest(true)
        )

        let began = await store.beginOperation(operationID)

        XCTAssertFalse(began)
        await assertStoreEqual(OperationState.completed) {
            await store.state(for: operationID)
        }
        await assertStoreEqual(Optional(true)) {
            integrityValue(await store.result(for: operationID))
        }
    }

    func testCancelledLastSubscriberKeepsReservedStateRecord() async {
        let probe = StoreProbe()
        let store = OperationObservationStore(
            policy: .init(maximumRecordCount: 1),
            debugProbe: probe.record
        )
        let operationID = OperationID()
        let stream = await store.register(operationID)
        _ = await probe.next()
        await store.setState(.queued, for: operationID)
        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        consumer.cancel()
        _ = await consumer.value
        let removalEvent = await probe.next()
        XCTAssertEqual(removalEvent, .subscriberRemoved(operationID))
        let recordCount = await store.debugRecordCount()
        XCTAssertEqual(recordCount, 1)
        let state = await store.state(for: operationID)
        XCTAssertEqual(state, .queued)
    }

    func testTerminalFinishClosesEveryContinuationExactlyOnce() async {
        let store = OperationObservationStore(policy: .init(maximumRecordCount: 4))
        let operationID = OperationID()
        let firstStream = await store.register(operationID)
        let secondStream = await store.register(operationID)
        let firstFinished = Task { await eventCount(firstStream) }
        let secondFinished = Task { await eventCount(secondStream) }

        await store.finishTerminal(operationID, state: .completed)
        await store.finishTerminal(operationID, state: .failed)

        await assertStoreEqual(0) { await firstFinished.value }
        await assertStoreEqual(0) { await secondFinished.value }
        let state = await store.state(for: operationID)
        XCTAssertEqual(state, .completed)
    }

    func testCancellationTerminalClearsStagedResult() async {
        let store = OperationObservationStore(policy: .init(maximumRecordCount: 4))
        let operationID = OperationID()
        await store.setState(.running, for: operationID)
        await store.publishResult(.integrityTest(true), for: operationID)

        await store.finishTerminal(operationID, state: .cancelled)

        let state = await store.state(for: operationID)
        let result = await store.result(for: operationID)
        XCTAssertEqual(state, .cancelled)
        XCTAssertNil(result)
    }

    func testResultRetentionEvictsOnlyOldestTerminalRecordsAtPolicyCap() async {
        let store = OperationObservationStore(policy: .init(maximumRecordCount: 2))
        let first = OperationID()
        let second = OperationID()
        let active = OperationID()

        _ = await store.register(first)
        await store.publishResult(
            .compression(.init(finalURLs: [URL(fileURLWithPath: "/first")])),
            for: first
        )
        await store.finishTerminal(first, state: .completed)

        _ = await store.register(active)
        await store.setState(.running, for: active)

        _ = await store.register(second)
        await store.publishResult(
            .compression(.init(finalURLs: [URL(fileURLWithPath: "/second")])),
            for: second
        )
        await store.finishTerminal(second, state: .completed)

        await assertStoreNil { await store.state(for: first) }
        await assertStoreNil { await store.result(for: first) }
        await assertStoreEqual(OperationState.running) { await store.state(for: active) }
        await assertStoreEqual(OperationState.completed) { await store.state(for: second) }
        await assertStoreEqual(Optional([URL(fileURLWithPath: "/second")])) {
            compressionURLs(await store.result(for: second))
        }
    }

    func testDismissAndTerminationRemoveResultProgressAndStateDeterministically() async {
        let store = OperationObservationStore(policy: .init(maximumRecordCount: 4))
        let dismissed = OperationID()
        let terminated = OperationID()
        let dismissedStream = await store.register(dismissed)
        let terminatedStream = await store.register(terminated)
        let dismissedFinished = Task { await eventCount(dismissedStream) }
        let terminatedFinished = Task { await eventCount(terminatedStream) }

        await store.setState(.running, for: dismissed)
        await store.publishResult(.integrityTest(true), for: dismissed)
        await store.remove(dismissed)

        await assertStoreEqual(0) { await dismissedFinished.value }
        await assertStoreNil { await store.state(for: dismissed) }
        await assertStoreNil { await store.result(for: dismissed) }

        await store.setState(.running, for: terminated)
        await store.publishResult(.archiveComment("comment"), for: terminated)
        await store.removeAll()

        await assertStoreEqual(0) { await terminatedFinished.value }
        await assertStoreNil { await store.state(for: terminated) }
        await assertStoreNil { await store.result(for: terminated) }
    }
}

private actor ObservationSignal {
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func signal() {
        count += 1
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in waiters {
            if count >= target {
                continuation.resume()
            } else {
                remaining.append((target, continuation))
            }
        }
        waiters = remaining
    }

    func wait(until target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }
}

private actor ObservationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private func eventCount(_ stream: AsyncStream<OperationProgressEvent>) async -> Int {
    var count = 0
    for await _ in stream {
        count += 1
    }
    return count
}

private func fraction(_ event: OperationProgressEvent?) -> Double? {
    guard case let .archive(progress)? = event else { return nil }
    return progress.fraction
}

private func compressionURLs(_ result: OperationResult?) -> [URL]? {
    guard case let .compression(compression)? = result else { return nil }
    return compression.finalURLs
}

private func integrityValue(_ result: OperationResult?) -> Bool? {
    guard case let .integrityTest(value)? = result else { return nil }
    return value
}

private final class StoreProbe: @unchecked Sendable {
    private let continuation: AsyncStream<OperationObservationStore.DebugEvent>.Continuation
    private let reader: StoreProbeReader

    init() {
        let pair = AsyncStream<OperationObservationStore.DebugEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        continuation = pair.continuation
        reader = StoreProbeReader(stream: pair.stream)
    }

    func record(_ event: OperationObservationStore.DebugEvent) {
        continuation.yield(event)
    }

    func next() async -> OperationObservationStore.DebugEvent {
        await reader.next()
    }
}

private actor StoreProbeReader {
    private var bufferedEvents: [OperationObservationStore.DebugEvent] = []
    private var waiters: [CheckedContinuation<OperationObservationStore.DebugEvent, Never>] = []

    init(stream: AsyncStream<OperationObservationStore.DebugEvent>) {
        Task { [weak self] in
            for await event in stream {
                await self?.record(event)
            }
        }
    }

    private func record(_ event: OperationObservationStore.DebugEvent) {
        if waiters.isEmpty {
            bufferedEvents.append(event)
        } else {
            waiters.removeFirst().resume(returning: event)
        }
    }

    func next() async -> OperationObservationStore.DebugEvent {
        if !bufferedEvents.isEmpty {
            return bufferedEvents.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private func assertStoreEqual<T: Equatable & Sendable>(
    _ expected: T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: @escaping @Sendable () async -> T
) async {
    let actual = await expression()
    XCTAssertEqual(actual, expected, file: file, line: line)
}

private func assertStoreNil<T: Sendable>(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: @escaping @Sendable () async -> T?
) async {
    let actual = await expression()
    XCTAssertNil(actual, file: file, line: line)
}
