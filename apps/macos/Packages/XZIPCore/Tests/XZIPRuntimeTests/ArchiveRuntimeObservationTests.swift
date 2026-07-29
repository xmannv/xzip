import Dispatch
import Foundation
import XCTest
import XZIPCore
import XZIPDomain
@testable import XZIPRuntime

final class ArchiveRuntimeObservationTests: XCTestCase {
    func testImmediateQueuedCancellationAfterOwnershipReservationNeverLaunchesBackend() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let calls = RuntimeCounter()
        let backend = ObservationBackend(test: { _, _ in
            await calls.increment()
            return true
        })
        let runtimeProbe = RuntimeProbe(blockOnReservation: true)
        let scheduler = ResourceScheduler(
            policy: schedulingPolicy(global: 1, metadata: 1, heavyPerVolume: 1)
        )
        let runtime = makeRuntime(
            backend: backend,
            scheduler: scheduler,
            debugProbe: runtimeProbe.record
        )
        let locator = try await runtime.openArchive(at: fixture.archive)
        let descriptor = descriptor(
            archiveID: locator.archiveID,
            payload: .test(.init(archive: .init(
                identity: locator.archiveID.identity,
                url: fixture.archive
            ))),
            title: "Queued test"
        )

        let operation = Task { try await runtime.executeOperation(descriptor) }
        let reserved = await runtimeProbe.next()
        XCTAssertEqual(reserved, .ownershipReserved(descriptor.operationID))
        operation.cancel()
        runtimeProbe.openReservationGate()

        await assertRuntimeTrue { await isCancellation(operation) }
        await assertRuntimeEqual(0) { await calls.value }
        await assertRuntimeEqual(OperationState.cancelled) {
            await runtime.state(for: descriptor.operationID)
        }
    }

    func testCallerCancellationAfterSchedulerGrantBeforeRunningNeverLaunchesBackendOrStops() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let calls = RuntimeCounter()
        let backend = ObservationBackend(test: { _, _ in
            await calls.increment()
            return true
        })
        let runtimeProbe = RuntimeProbe(blockOnPermitGranted: true)
        let scheduler = ResourceScheduler(
            policy: schedulingPolicy(global: 1, metadata: 1, heavyPerVolume: 1)
        )
        let runtime = makeRuntime(
            backend: backend,
            scheduler: scheduler,
            debugProbe: runtimeProbe.record
        )
        let locator = try await runtime.openArchive(at: fixture.archive)
        let descriptor = descriptor(
            archiveID: locator.archiveID,
            payload: .test(.init(archive: .init(
                identity: locator.archiveID.identity,
                url: fixture.archive
            ))),
            title: "Granted queued cancellation"
        )

        let operation = Task { try await runtime.executeOperation(descriptor) }
        let reserved = await runtimeProbe.next()
        XCTAssertEqual(reserved, .ownershipReserved(descriptor.operationID))
        let granted = await runtimeProbe.next()
        XCTAssertEqual(granted, .permitGranted(descriptor.operationID))

        operation.cancel()
        runtimeProbe.openPermitGrantedGate()

        await assertRuntimeTrue { await isCancellation(operation) }
        await assertRuntimeEqual(0) { await calls.value }
        await assertRuntimeEqual(OperationState.cancelled) {
            await runtime.state(for: descriptor.operationID)
        }
        await assertRuntimeNil { await runtime.result(for: descriptor.operationID) }

        var remainingEvents: [ArchiveRuntime.DebugEvent] = []
        while true {
            let event = await runtimeProbe.next()
            remainingEvents.append(event)
            if case let .ownershipRemoved(operationID) = event,
               operationID == descriptor.operationID {
                break
            }
        }
        XCTAssertFalse(remainingEvents.contains(
            .stateChanged(descriptor.operationID, .stopping)
        ))
    }

    func testRunningCancellationTransitionsStoppingThenCancelled() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let entered = RuntimeSignal()
        let cancellationObserved = RuntimeSignal()
        let allowFailure = RuntimeGate()
        let backendCancellation = RuntimeCancellationGate()
        let backend = ObservationBackend(test: { _, _ in
            await entered.signal()
            do {
                try await backendCancellation.wait()
                return true
            } catch {
                await cancellationObserved.signal()
                await allowFailure.wait()
                throw ObservationProbeError.expected
            }
        })
        let scheduler = ResourceScheduler(
            policy: schedulingPolicy(global: 1, metadata: 1, heavyPerVolume: 1)
        )
        let runtime = makeRuntime(backend: backend, scheduler: scheduler)
        let locator = try await runtime.openArchive(at: fixture.archive)
        let descriptor = descriptor(
            archiveID: locator.archiveID,
            payload: .test(.init(archive: .init(
                identity: locator.archiveID.identity,
                url: fixture.archive
            ))),
            title: "Running test"
        )

        let operation = Task { try await runtime.executeOperation(descriptor) }
        await entered.wait(until: 1)
        await assertRuntimeEqual(OperationState.running) {
            await runtime.state(for: descriptor.operationID)
        }

        await runtime.cancelOperation(descriptor.operationID)
        await cancellationObserved.wait(until: 1)
        await assertRuntimeEqual(OperationState.stopping) {
            await runtime.state(for: descriptor.operationID)
        }

        await allowFailure.open()
        await assertRuntimeTrue { await isCancellation(operation) }
        await assertRuntimeEqual(OperationState.cancelled) {
            await runtime.state(for: descriptor.operationID)
        }
    }

    func testFastCooperativeBackendExplicitCancellationPublishesStoppingBeforeCancelled() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let entered = RuntimeSignal()
        let backendCancellation = RuntimeCancellationGate()
        let backend = ObservationBackend(test: { _, _ in
            await entered.signal()
            try await backendCancellation.wait()
            return true
        })
        let scheduler = ResourceScheduler(
            policy: schedulingPolicy(global: 1, metadata: 1, heavyPerVolume: 1)
        )
        let runtimeProbe = RuntimeProbe()
        let runtime = makeRuntime(
            backend: backend,
            scheduler: scheduler,
            debugProbe: runtimeProbe.record
        )
        let locator = try await runtime.openArchive(at: fixture.archive)
        let descriptor = descriptor(
            archiveID: locator.archiveID,
            payload: .test(.init(archive: .init(
                identity: locator.archiveID.identity,
                url: fixture.archive
            ))),
            title: "Fast explicit cancellation"
        )

        let operation = Task { try await runtime.executeOperation(descriptor) }
        let reserved = await runtimeProbe.next()
        XCTAssertEqual(reserved, .ownershipReserved(descriptor.operationID))
        let granted = await runtimeProbe.next()
        XCTAssertEqual(granted, .permitGranted(descriptor.operationID))
        await entered.wait(until: 1)

        await runtime.cancelOperation(descriptor.operationID)

        let stopping = await runtimeProbe.next()
        XCTAssertEqual(stopping, .stateChanged(descriptor.operationID, .stopping))
        let cancellation = await runtimeProbe.next()
        XCTAssertEqual(cancellation, .cancellationRequested(descriptor.operationID))
        await assertRuntimeTrue { await isCancellation(operation) }
        let finalized = await runtimeProbe.next()
        XCTAssertEqual(finalized, .finalized(descriptor.operationID, .cancelled))
        await assertRuntimeEqual(OperationState.cancelled) {
            await runtime.state(for: descriptor.operationID)
        }
        await assertRuntimeNil { await runtime.result(for: descriptor.operationID) }
    }

    func testRunningCallerTaskCancellationTransitionsStoppingThenCancelledAfterBackendUnwinds() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let entered = RuntimeSignal()
        let cancellationObserved = RuntimeSignal()
        let allowFailure = RuntimeGate()
        let backendCancellation = RuntimeCancellationGate()
        let backend = ObservationBackend(test: { _, _ in
            await entered.signal()
            do {
                try await backendCancellation.wait()
                return true
            } catch {
                await cancellationObserved.signal()
                await allowFailure.wait()
                throw ObservationProbeError.expected
            }
        })
        let scheduler = ResourceScheduler(
            policy: schedulingPolicy(global: 1, metadata: 1, heavyPerVolume: 1)
        )
        let runtime = makeRuntime(backend: backend, scheduler: scheduler)
        let locator = try await runtime.openArchive(at: fixture.archive)
        let descriptor = descriptor(
            archiveID: locator.archiveID,
            payload: .test(.init(archive: .init(
                identity: locator.archiveID.identity,
                url: fixture.archive
            ))),
            title: "Caller-cancelled running test"
        )

        let operation = Task { try await runtime.executeOperation(descriptor) }
        await entered.wait(until: 1)
        await assertRuntimeEqual(OperationState.running) {
            await runtime.state(for: descriptor.operationID)
        }

        operation.cancel()
        await cancellationObserved.wait(until: 1)
        await assertRuntimeEqual(OperationState.stopping) {
            await runtime.state(for: descriptor.operationID)
        }
        await assertRuntimeNil { await runtime.result(for: descriptor.operationID) }

        await allowFailure.open()
        await assertRuntimeTrue { await isCancellation(operation) }
        await assertRuntimeEqual(OperationState.cancelled) {
            await runtime.state(for: descriptor.operationID)
        }
        await assertRuntimeNil { await runtime.result(for: descriptor.operationID) }
    }

    func testCancelIgnoringBackendCannotPublishOrRetainSuccess() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let entered = RuntimeSignal()
        let allowReturn = RuntimeGate()
        let backend = ObservationBackend(test: { _, _ in
            await entered.signal()
            await allowReturn.wait()
            return true
        })
        let scheduler = ResourceScheduler(
            policy: schedulingPolicy(global: 1, metadata: 1, heavyPerVolume: 1)
        )
        let runtime = makeRuntime(backend: backend, scheduler: scheduler)
        let locator = try await runtime.openArchive(at: fixture.archive)
        let descriptor = descriptor(
            archiveID: locator.archiveID,
            payload: .test(.init(archive: .init(
                identity: locator.archiveID.identity,
                url: fixture.archive
            ))),
            title: "Cancellation-ignoring test"
        )

        let operation = Task { try await runtime.executeOperation(descriptor) }
        await entered.wait(until: 1)
        await runtime.cancelOperation(descriptor.operationID)
        await assertRuntimeEqual(OperationState.stopping) {
            await runtime.state(for: descriptor.operationID)
        }
        await allowReturn.open()

        await assertRuntimeTrue { await isCancellation(operation) }
        await assertRuntimeEqual(OperationState.cancelled) {
            await runtime.state(for: descriptor.operationID)
        }
        await assertRuntimeNil { await runtime.result(for: descriptor.operationID) }
    }

    func testDuplicateOperationIDIsRejectedWithoutOverwritingOwner() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let entered = RuntimeSignal()
        let allowReturn = RuntimeGate()
        let backend = ObservationBackend(test: { _, _ in
            await entered.signal()
            await allowReturn.wait()
            return true
        })
        let scheduler = ResourceScheduler(
            policy: schedulingPolicy(global: 2, metadata: 2, heavyPerVolume: 1)
        )
        let runtime = makeRuntime(backend: backend, scheduler: scheduler)
        let locator = try await runtime.openArchive(at: fixture.archive)
        let operationID = OperationID()
        let descriptor = descriptor(
            operationID: operationID,
            archiveID: locator.archiveID,
            payload: .test(.init(archive: .init(
                identity: locator.archiveID.identity,
                url: fixture.archive
            ))),
            title: "Duplicate test"
        )

        let first = Task { try await runtime.executeOperation(descriptor) }
        await entered.wait(until: 1)
        do {
            try await runtime.executeOperation(descriptor)
            XCTFail("Expected duplicate operation rejection")
        } catch ArchiveRuntimeValidationError.duplicateOperationID {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await allowReturn.open()
        try await first.value
        await assertRuntimeEqual(OperationState.completed) {
            await runtime.state(for: operationID)
        }
        await assertRuntimeEqual(Optional(true)) {
            integrityValue(await runtime.result(for: operationID))
        }
    }

    func testCompletedOperationIDReuseIsRejectedWithoutLaunchingBackendOrMutatingRetainedObservation() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let calls = RuntimeCounter()
        let backend = ObservationBackend(test: { _, _ in
            await calls.increment()
            return true
        })
        let scheduler = ResourceScheduler(
            policy: schedulingPolicy(global: 1, metadata: 1, heavyPerVolume: 1)
        )
        let runtime = makeRuntime(backend: backend, scheduler: scheduler)
        let locator = try await runtime.openArchive(at: fixture.archive)
        let operationID = OperationID()
        let descriptor = descriptor(
            operationID: operationID,
            archiveID: locator.archiveID,
            payload: .test(.init(archive: .init(
                identity: locator.archiveID.identity,
                url: fixture.archive
            ))),
            title: "Retained operation"
        )

        try await runtime.executeOperation(descriptor)
        await assertRuntimeEqual(1) { await calls.value }
        await assertRuntimeEqual(OperationState.completed) {
            await runtime.state(for: operationID)
        }
        await assertRuntimeEqual(Optional(true)) {
            integrityValue(await runtime.result(for: operationID))
        }

        do {
            try await runtime.executeOperation(descriptor)
            XCTFail("Expected retained operation ID rejection")
        } catch ArchiveRuntimeValidationError.duplicateOperationID {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await assertRuntimeEqual(1) { await calls.value }
        await assertRuntimeEqual(OperationState.completed) {
            await runtime.state(for: operationID)
        }
        await assertRuntimeEqual(Optional(true)) {
            integrityValue(await runtime.result(for: operationID))
        }
    }

    func testInvalidDescriptorInsideOwnedLifecycleFailsAndClosesPreSubscription() async {
        let fixture = try? RuntimeFixture()
        guard let fixture else {
            XCTFail("Failed to create fixture")
            return
        }
        defer { fixture.remove() }
        let scheduler = ResourceScheduler(
            policy: schedulingPolicy(global: 1, metadata: 1, heavyPerVolume: 1)
        )
        let runtime = makeRuntime(
            backend: ObservationBackend(),
            scheduler: scheduler
        )
        let descriptor = OperationDescriptor(
            sessionID: ArchiveSessionID(),
            payload: .brokerCommand(.init(schemaVersion: 1, encodedCommand: Data())),
            resourcePolicy: .production,
            ui: .init(title: "Invalid")
        )
        let stream = await runtime.progress(for: descriptor.operationID)
        let completion = Task { await collectEvents(stream) }

        do {
            try await runtime.executeOperation(descriptor)
            XCTFail("Expected descriptor validation failure")
        } catch ArchiveRuntimeValidationError.sessionRequiresArchive {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await completion.value
        XCTAssertTrue(events.isEmpty)
        await assertRuntimeEqual(OperationState.failed) {
            await runtime.state(for: descriptor.operationID)
        }
        await assertRuntimeNil { await runtime.result(for: descriptor.operationID) }
    }

    func testTerminalSuccessAndFailureCannotBeDroppedByProgressBuffer() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let scheduler = ResourceScheduler(
            policy: schedulingPolicy(global: 2, metadata: 2, heavyPerVolume: 1)
        )
        let successfulBackend = ObservationBackend(compress: { _, _, _ in
            progressStream(count: 1_000)
        })
        let successfulRuntime = makeRuntime(
            backend: successfulBackend,
            scheduler: scheduler
        )
        let successDescriptor = descriptor(
            payload: .compress(compressionPayload(
                source: fixture.source,
                destination: fixture.root.appendingPathComponent("success.zip")
            )),
            title: "Successful compression"
        )
        let successProgress = await successfulRuntime.progress(
            for: successDescriptor.operationID
        )
        let successEvents = Task { await collectEvents(successProgress) }

        try await successfulRuntime.executeOperation(successDescriptor)

        let completedState = await successfulRuntime.state(for: successDescriptor.operationID)
        XCTAssertEqual(completedState, .completed)
        await assertRuntimeNil {
            await successfulRuntime.result(for: successDescriptor.operationID)
        }
        await assertRuntimeFalse { await successEvents.value.isEmpty }

        let failingBackend = ObservationBackend(compress: { _, _, _ in
            AsyncThrowingStream { continuation in
                for index in 0..<1_000 {
                    continuation.yield(Double(index) / 999)
                }
                continuation.finish(throwing: ObservationProbeError.expected)
            }
        })
        let failingRuntime = makeRuntime(backend: failingBackend, scheduler: scheduler)
        let failureDescriptor = descriptor(
            payload: .compress(compressionPayload(
                source: fixture.source,
                destination: fixture.root.appendingPathComponent("failure.zip")
            )),
            title: "Failing compression"
        )
        let failureProgress = await failingRuntime.progress(for: failureDescriptor.operationID)
        let failureEvents = Task { await collectEvents(failureProgress) }

        do {
            try await failingRuntime.executeOperation(failureDescriptor)
            XCTFail("Expected compression failure")
        } catch ObservationProbeError.expected {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let failedState = await failingRuntime.state(for: failureDescriptor.operationID)
        XCTAssertEqual(failedState, .failed)
        await assertRuntimeNil { await failingRuntime.result(for: failureDescriptor.operationID) }
        await assertRuntimeFalse { await failureEvents.value.isEmpty }
    }

    func testOperationsPublishOnlyTheirDefinedResults() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let backend = ObservationBackend(
            readComment: { _ in "archive comment" },
            test: { _, _ in true },
            compress: { _, _, _ in progressStream(count: 2) }
        )
        let scheduler = ResourceScheduler(
            policy: schedulingPolicy(global: 2, metadata: 2, heavyPerVolume: 2)
        )
        let runtime = makeRuntime(
            backend: backend,
            scheduler: scheduler,
            extractionHandler: ObservationExtractionHandler()
        )
        let locator = try await runtime.openArchive(at: fixture.archive)
        let archiveReference = OperationResourceReference(
            identity: locator.archiveID.identity,
            url: fixture.archive
        )

        let testDescriptor = descriptor(
            archiveID: locator.archiveID,
            payload: .test(.init(archive: archiveReference)),
            title: "Test"
        )
        try await runtime.executeOperation(testDescriptor)
        await assertRuntimeEqual(Optional(true)) {
            integrityValue(await runtime.result(for: testDescriptor.operationID))
        }

        let commentDescriptor = descriptor(
            archiveID: locator.archiveID,
            payload: .readComment(.init(archive: archiveReference)),
            title: "Comment"
        )
        try await runtime.executeOperation(commentDescriptor)
        await assertRuntimeEqual(Optional("archive comment")) {
            commentValue(await runtime.result(for: commentDescriptor.operationID))
        }

        let extractionDescriptor = descriptor(
            archiveID: locator.archiveID,
            payload: .extract(.init(
                archive: archiveReference,
                destination: .init(
                    identity: nil,
                    url: fixture.root.appendingPathComponent("extracted", isDirectory: true)
                ),
                selectedEntryPaths: [],
                conflictPolicy: .fail,
                preserveTimestamps: true
            )),
            title: "Extract"
        )
        try await runtime.executeOperation(extractionDescriptor)
        await assertRuntimeTrue {
            extractionValue(await runtime.result(for: extractionDescriptor.operationID)) != nil
        }

        let compressionDescriptor = descriptor(
            payload: .compress(compressionPayload(
                source: fixture.source,
                destination: fixture.root.appendingPathComponent("compressed.zip")
            )),
            title: "Compress"
        )
        try await runtime.executeOperation(compressionDescriptor)
        await assertRuntimeNil { await runtime.result(for: compressionDescriptor.operationID) }
    }

    func testSameVolumeCompressionUsesPerVolumeCap() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let entered = RuntimeSignal()
        let allowFinish = RuntimeGate()
        let backend = ObservationBackend(compress: { _, _, _ in
            gatedProgressStream(entered: entered, allowFinish: allowFinish)
        })
        let probe = RuntimeSchedulerProbe()
        let scheduler = ResourceScheduler(
            policy: schedulingPolicy(global: 2, metadata: 2, heavyPerVolume: 1),
            debugProbe: probe.record
        )
        let runtime = makeRuntime(
            backend: backend,
            scheduler: scheduler,
            volumeIdentifierProvider: { _ in 7 }
        )
        let firstDescriptor = descriptor(
            payload: .compress(compressionPayload(
                source: fixture.source,
                destination: fixture.root.appendingPathComponent("first.zip")
            )),
            title: "First compression"
        )
        let secondDescriptor = descriptor(
            payload: .compress(compressionPayload(
                source: fixture.source,
                destination: fixture.root.appendingPathComponent("second.zip")
            )),
            title: "Second compression"
        )
        let workload = ProcessWorkload.heavyIO(volumeIDs: [7])

        let first = Task { try await runtime.executeOperation(firstDescriptor) }
        let firstID = await expectRuntimeSchedulerEvent(.enqueued, workload: workload, from: probe)
        _ = await expectRuntimeSchedulerEvent(
            .granted,
            workload: workload,
            id: firstID,
            from: probe
        )
        await entered.wait(until: 1)
        let second = Task { try await runtime.executeOperation(secondDescriptor) }
        let secondID = await expectRuntimeSchedulerEvent(.enqueued, workload: workload, from: probe)
        _ = await expectRuntimeSchedulerEvent(
            .waiting,
            workload: workload,
            id: secondID,
            from: probe
        )

        await allowFinish.open()
        try await first.value
        _ = await expectRuntimeSchedulerEvent(
            .released,
            workload: workload,
            id: firstID,
            from: probe
        )
        _ = await expectRuntimeSchedulerEvent(
            .granted,
            workload: workload,
            id: secondID,
            from: probe
        )
        try await second.value
    }

    func testCrossVolumeExtractionClaimsArchiveAndDestinationAtomically() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let probe = RuntimeSchedulerProbe()
        let scheduler = ResourceScheduler(
            policy: schedulingPolicy(global: 2, metadata: 2, heavyPerVolume: 1),
            debugProbe: probe.record
        )
        let runtime = makeRuntime(
            backend: ObservationBackend(),
            scheduler: scheduler,
            volumeIdentifierProvider: volumeProvider([
                fixture.archive: 1,
                fixture.root.appendingPathComponent("destination", isDirectory: true): 2
            ]),
            extractionHandler: ObservationExtractionHandler()
        )
        let locator = try await runtime.openArchive(at: fixture.archive)
        let destination = fixture.root.appendingPathComponent("destination", isDirectory: true)
        let descriptor = descriptor(
            archiveID: locator.archiveID,
            payload: .extract(.init(
                archive: .init(identity: locator.archiveID.identity, url: fixture.archive),
                destination: .init(identity: nil, url: destination),
                selectedEntryPaths: [],
                conflictPolicy: .fail,
                preserveTimestamps: true
            )),
            title: "Cross-volume extraction"
        )
        let workload = ProcessWorkload.heavyIO(volumeIDs: [1, 2])

        try await runtime.executeOperation(descriptor)
        let id = await expectRuntimeSchedulerEvent(.enqueued, workload: workload, from: probe)
        _ = await expectRuntimeSchedulerEvent(
            .granted,
            workload: workload,
            id: id,
            from: probe
        )
        await assertRuntimeTrue {
            extractionValue(await runtime.result(for: descriptor.operationID)) != nil
        }
    }

    func testJoinMultiVolumeClaimPreservesSchedulerFairness() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let secondPart = fixture.root.appendingPathComponent("part.002")
        try Data("part".utf8).write(to: secondPart)
        let joinEntered = RuntimeSignal()
        let allowJoin = RuntimeGate()
        let backend = ObservationBackend(
            compress: { _, _, _ in progressStream(count: 0) },
            join: { _, _ in gatedProgressStream(
                entered: joinEntered,
                allowFinish: allowJoin
            ) }
        )
        let probe = RuntimeSchedulerProbe()
        let scheduler = ResourceScheduler(
            policy: schedulingPolicy(global: 4, metadata: 4, heavyPerVolume: 1),
            debugProbe: probe.record
        )
        let joinDestination = fixture.root.appendingPathComponent("joined.zip")
        let compressDestination = fixture.root.appendingPathComponent("compressed.zip")
        let runtime = makeRuntime(
            backend: backend,
            scheduler: scheduler,
            volumeIdentifierProvider: volumeProvider([
                fixture.source: 1,
                secondPart: 2,
                joinDestination: 3,
                compressDestination: 2
            ], defaultVolume: 2)
        )
        let holderWorkload = ProcessWorkload.heavyIO(volumeIDs: [1])
        let holder = try await scheduler.acquire(.init(workload: holderWorkload))
        let holderID = await expectRuntimeSchedulerEvent(
            .enqueued,
            workload: holderWorkload,
            from: probe
        )
        _ = await expectRuntimeSchedulerEvent(
            .granted,
            workload: holderWorkload,
            id: holderID,
            from: probe
        )
        let joinDescriptor = descriptor(
            payload: .joinSplit(.init(
                parts: [
                    .init(identity: nil, url: fixture.source),
                    .init(identity: nil, url: secondPart)
                ],
                destination: .init(identity: nil, url: joinDestination),
                preserveTimestamps: true
            )),
            title: "Join"
        )
        let joinWorkload = ProcessWorkload.heavyIO(volumeIDs: [1, 2, 3])
        let join = Task { try await runtime.executeOperation(joinDescriptor) }
        let joinID = await expectRuntimeSchedulerEvent(.enqueued, workload: joinWorkload, from: probe)
        _ = await expectRuntimeSchedulerEvent(
            .waiting,
            workload: joinWorkload,
            id: joinID,
            from: probe
        )
        let compressionDescriptor = descriptor(
            payload: .compress(compressionPayload(
                source: secondPart,
                destination: compressDestination
            )),
            title: "Compression behind join"
        )
        let compressionWorkload = ProcessWorkload.heavyIO(volumeIDs: [2])
        let compression = Task { try await runtime.executeOperation(compressionDescriptor) }
        let compressionID = await expectRuntimeSchedulerEvent(
            .enqueued,
            workload: compressionWorkload,
            from: probe
        )
        _ = await expectRuntimeSchedulerEvent(
            .waiting,
            workload: compressionWorkload,
            id: compressionID,
            from: probe
        )

        await holder.release()
        _ = await expectRuntimeSchedulerEvent(
            .released,
            workload: holderWorkload,
            id: holderID,
            from: probe
        )
        _ = await expectRuntimeSchedulerEvent(
            .granted,
            workload: joinWorkload,
            id: joinID,
            from: probe
        )
        await joinEntered.wait(until: 1)
        await allowJoin.open()
        try await join.value
        _ = await expectRuntimeSchedulerEvent(
            .released,
            workload: joinWorkload,
            id: joinID,
            from: probe
        )
        _ = await expectRuntimeSchedulerEvent(
            .granted,
            workload: compressionWorkload,
            id: compressionID,
            from: probe
        )
        try await compression.value
    }

    func testArchiveAndRepackProgressPublicationUsesExactCases() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let backend = ObservationBackend(
            repack: { _, _, _, onStep in
                onStep(.decompress)
                onStep(.addFiles)
                onStep(.recompress)
            },
            join: { _, _ in progressStream(count: 3) }
        )
        let scheduler = ResourceScheduler(
            policy: schedulingPolicy(global: 2, metadata: 2, heavyPerVolume: 2)
        )
        let runtime = makeRuntime(backend: backend, scheduler: scheduler)
        let locator = try await runtime.openArchive(at: fixture.archive)
        let archiveReference = OperationResourceReference(
            identity: locator.archiveID.identity,
            url: fixture.archive
        )

        let repackDescriptor = descriptor(
            archiveID: locator.archiveID,
            payload: .repackAdd(.init(
                archive: archiveReference,
                sources: [.init(identity: nil, url: fixture.source)],
                workingDirectory: nil
            )),
            title: "Repack"
        )
        let repackProgress = await runtime.progress(for: repackDescriptor.operationID)
        let repackEvents = Task { await collectEvents(repackProgress) }
        try await runtime.executeOperation(repackDescriptor)
        let repackValues = await repackEvents.value.compactMap(repackStep)
        XCTAssertEqual(repackValues.last, RepackStep.recompress)

        let joinDestination = fixture.root.appendingPathComponent("joined.zip")
        let joinDescriptor = descriptor(
            payload: .joinSplit(.init(
                parts: [.init(identity: nil, url: fixture.source)],
                destination: .init(identity: nil, url: joinDestination),
                preserveTimestamps: true
            )),
            title: "Join"
        )
        let joinProgress = await runtime.progress(for: joinDescriptor.operationID)
        let joinEvents = Task { await collectEvents(joinProgress) }
        try await runtime.executeOperation(joinDescriptor)
        let archiveFractions = await joinEvents.value.compactMap(archiveFraction)
        XCTAssertEqual(archiveFractions.last, 1)
        await assertRuntimeNil { await runtime.result(for: joinDescriptor.operationID) }
    }
}

private enum ObservationProbeError: Error {
    case expected
}

private final class ObservationBackend: ArchiveBackend, @unchecked Sendable {
    typealias ReadCommentHandler = @Sendable (URL) async throws -> String
    typealias TestHandler = @Sendable (URL, String?) async throws -> Bool
    typealias ProgressHandler = @Sendable ([URL], URL, CompressionOptions) throws -> AsyncThrowingStream<Double, Error>
    typealias ExtractHandler = @Sendable (URL, URL, ExtractionOptions) throws -> AsyncThrowingStream<Double, Error>
    typealias RepackHandler = @Sendable ([URL], URL, URL, @escaping @Sendable (RepackStep) -> Void) async throws -> Void
    typealias JoinHandler = @Sendable ([URL], URL) -> AsyncThrowingStream<Double, Error>

    private let readCommentHandler: ReadCommentHandler
    private let testHandler: TestHandler
    private let compressHandler: ProgressHandler
    private let extractHandler: ExtractHandler
    private let repackHandler: RepackHandler
    private let joinHandler: JoinHandler

    init(
        readComment: @escaping ReadCommentHandler = { _ in "" },
        test: @escaping TestHandler = { _, _ in true },
        compress: @escaping ProgressHandler = { _, _, _ in progressStream(count: 0) },
        extract: @escaping ExtractHandler = { _, _, _ in progressStream(count: 0) },
        repack: @escaping RepackHandler = { _, _, _, _ in },
        join: @escaping JoinHandler = { _, _ in progressStream(count: 0) }
    ) {
        self.readCommentHandler = readComment
        self.testHandler = test
        self.compressHandler = compress
        self.extractHandler = extract
        self.repackHandler = repack
        self.joinHandler = join
    }

    func readComment(for archive: URL) async throws -> String {
        try await readCommentHandler(archive)
    }

    func writeComment(_ comment: String, to archive: URL) async throws {}
    func canEditComment(for archive: URL) -> Bool { false }
    func detectSplit(part: URL) throws -> SplitArchiveJoiner.DetectionResult? { nil }

    func joinSplit(parts: [URL], destination: URL) -> AsyncThrowingStream<Double, Error> {
        joinHandler(parts, destination)
    }

    func compress(
        sources: [URL],
        destination: URL,
        options: CompressionOptions
    ) throws -> AsyncThrowingStream<Double, Error> {
        try compressHandler(sources, destination, options)
    }

    func extract(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) throws -> AsyncThrowingStream<Double, Error> {
        try extractHandler(archive, destination, options)
    }

    func detectedFormat(for archive: URL) -> ArchiveFormat? { nil }
    func list(archive: URL, password: String?) async throws -> [ArchiveEntry] { [] }

    func list(
        archive: URL,
        password: String?,
        limit: Int
    ) async throws -> ArchiveListingResult {
        ArchiveListingResult(entries: [], truncated: false)
    }

    func test(archive: URL, password: String?) async throws -> Bool {
        try await testHandler(archive, password)
    }

    func add(
        files: [URL],
        to archive: URL,
        password: String?,
        workingDirectory: URL?
    ) async throws {}

    func addViaRepack(
        files: [URL],
        to archive: URL,
        workspace: URL,
        onStep: @escaping @Sendable (RepackStep) -> Void
    ) async throws {
        try await repackHandler(files, archive, workspace, onStep)
    }

    func delete(entries: [String], from archive: URL, password: String?) async throws {}

    func rename(
        pairs: [(entry: String, newName: String)],
        in archive: URL,
        password: String?
    ) async throws {}

    func update(
        entry entryPath: String,
        from workingDirectory: URL,
        in archive: URL,
        password: String?
    ) async throws {}
}

private struct RuntimeFixture {
    let root: URL
    let archive: URL
    let source: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        archive = root.appendingPathComponent("archive.zip")
        source = root.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("archive".utf8).write(to: archive)
        try Data("source".utf8).write(to: source)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor RuntimeCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor RuntimeSignal {
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

private actor RuntimeGate {
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

private final class RuntimeCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var isCancelled = false

    func wait() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }
}

private final class RuntimeProbe: @unchecked Sendable {
    private let continuation: AsyncStream<ArchiveRuntime.DebugEvent>.Continuation
    private let reader: RuntimeProbeReader
    private let lock = NSLock()
    private var shouldBlockOnReservation: Bool
    private var shouldBlockOnPermitGranted: Bool
    private let reservationGate: DispatchSemaphore?
    private let permitGrantedGate: DispatchSemaphore?

    init(
        blockOnReservation: Bool = false,
        blockOnPermitGranted: Bool = false
    ) {
        let pair = AsyncStream<ArchiveRuntime.DebugEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        continuation = pair.continuation
        reader = RuntimeProbeReader(stream: pair.stream)
        shouldBlockOnReservation = blockOnReservation
        shouldBlockOnPermitGranted = blockOnPermitGranted
        reservationGate = blockOnReservation ? DispatchSemaphore(value: 0) : nil
        permitGrantedGate = blockOnPermitGranted ? DispatchSemaphore(value: 0) : nil
    }

    func record(_ event: ArchiveRuntime.DebugEvent) {
        continuation.yield(event)

        lock.lock()
        let gate: DispatchSemaphore?
        switch event {
        case .ownershipReserved where shouldBlockOnReservation:
            shouldBlockOnReservation = false
            gate = reservationGate
        case .permitGranted where shouldBlockOnPermitGranted:
            shouldBlockOnPermitGranted = false
            gate = permitGrantedGate
        default:
            gate = nil
        }
        lock.unlock()
        gate?.wait()
    }

    func next() async -> ArchiveRuntime.DebugEvent {
        await reader.next()
    }

    func openReservationGate() {
        reservationGate?.signal()
    }

    func openPermitGrantedGate() {
        permitGrantedGate?.signal()
    }
}

private actor RuntimeProbeReader {
    private var bufferedEvents: [ArchiveRuntime.DebugEvent] = []
    private var waiters: [CheckedContinuation<ArchiveRuntime.DebugEvent, Never>] = []

    init(stream: AsyncStream<ArchiveRuntime.DebugEvent>) {
        Task { [weak self] in
            for await event in stream {
                await self?.record(event)
            }
        }
    }

    private func record(_ event: ArchiveRuntime.DebugEvent) {
        if waiters.isEmpty {
            bufferedEvents.append(event)
        } else {
            waiters.removeFirst().resume(returning: event)
        }
    }

    func next() async -> ArchiveRuntime.DebugEvent {
        if !bufferedEvents.isEmpty {
            return bufferedEvents.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private enum RuntimeSchedulerEventKind: Equatable {
    case enqueued
    case waiting
    case granted
    case cancelled
    case released
}

private final class RuntimeSchedulerProbe: @unchecked Sendable {
    private let continuation: AsyncStream<ResourceScheduler.DebugEvent>.Continuation
    private let reader: RuntimeSchedulerProbeReader

    init() {
        let pair = AsyncStream<ResourceScheduler.DebugEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        continuation = pair.continuation
        reader = RuntimeSchedulerProbeReader(stream: pair.stream)
    }

    func record(_ event: ResourceScheduler.DebugEvent) {
        continuation.yield(event)
    }

    func next() async -> ResourceScheduler.DebugEvent {
        await reader.next()
    }
}

private actor RuntimeSchedulerProbeReader {
    private var bufferedEvents: [ResourceScheduler.DebugEvent] = []
    private var waiters: [CheckedContinuation<ResourceScheduler.DebugEvent, Never>] = []

    init(stream: AsyncStream<ResourceScheduler.DebugEvent>) {
        Task { [weak self] in
            for await event in stream {
                await self?.record(event)
            }
        }
    }

    private func record(_ event: ResourceScheduler.DebugEvent) {
        if waiters.isEmpty {
            bufferedEvents.append(event)
        } else {
            waiters.removeFirst().resume(returning: event)
        }
    }

    func next() async -> ResourceScheduler.DebugEvent {
        if !bufferedEvents.isEmpty {
            return bufferedEvents.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@discardableResult
private func expectRuntimeSchedulerEvent(
    _ kind: RuntimeSchedulerEventKind,
    workload: ProcessWorkload,
    id expectedID: UUID? = nil,
    from probe: RuntimeSchedulerProbe,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> UUID {
    let parts = runtimeSchedulerEventParts(await probe.next())
    XCTAssertEqual(parts.kind, kind, file: file, line: line)
    XCTAssertEqual(parts.workload, workload, file: file, line: line)
    if let expectedID {
        XCTAssertEqual(parts.id, expectedID, file: file, line: line)
    }
    return parts.id
}

private func runtimeSchedulerEventParts(
    _ event: ResourceScheduler.DebugEvent
) -> (kind: RuntimeSchedulerEventKind, id: UUID, workload: ProcessWorkload) {
    switch event {
    case let .enqueued(id, workload):
        return (.enqueued, id, workload)
    case let .waiting(id, workload):
        return (.waiting, id, workload)
    case let .granted(id, workload):
        return (.granted, id, workload)
    case let .cancelled(id, workload):
        return (.cancelled, id, workload)
    case let .released(id, workload):
        return (.released, id, workload)
    }
}

private struct ObservationExtractionHandler: ArchiveExtractionHandling {
    func preflight(
        request: ExtractionPreflightRequest
    ) async throws -> ExtractionPreflight {
        throw ObservationProbeError.expected
    }

    func prepare(
        descriptor: OperationDescriptor
    ) async throws -> ArchiveExtractionPreparation {
        .fresh
    }

    func executeFresh(
        payload: ExtractionOperationPayload,
        descriptor: OperationDescriptor,
        progress: @Sendable (ArchiveProgress) async -> Void
    ) async throws -> ArchiveExtractionExecution {
        ArchiveExtractionExecution(
            result: ExtractionResult(
                transactionID: TransactionID(),
                publishedURLs: [],
                skippedPaths: []
            ),
            postTerminalFinalizer: {}
        )
    }
}

private func makeRuntime(
    backend: any ArchiveBackend,
    scheduler: ResourceScheduler,
    volumeIdentifierProvider: @escaping @Sendable (URL) throws -> UInt64 = {
        try ArchiveIdentityResolver().stableVolumeIdentifier(for: $0)
    },
    debugProbe: (@Sendable (ArchiveRuntime.DebugEvent) -> Void)? = nil,
    extractionHandler: (any ArchiveExtractionHandling)? = nil
) -> ArchiveRuntime {
    ArchiveRuntime(
        backend: backend,
        identityResolver: ArchiveIdentityResolver(),
        scheduler: scheduler,
        observationPolicy: .init(maximumRecordCount: 32),
        volumeIdentifierProvider: volumeIdentifierProvider,
        debugProbe: debugProbe,
        extractionHandler: extractionHandler
    )
}

private func descriptor(
    operationID: OperationID = OperationID(),
    archiveID: ArchiveID? = nil,
    sessionID: ArchiveSessionID? = nil,
    payload: OperationPayload,
    title: String
) -> OperationDescriptor {
    OperationDescriptor(
        operationID: operationID,
        archiveID: archiveID,
        sessionID: sessionID,
        payload: payload,
        resourcePolicy: .production,
        ui: .init(title: title)
    )
}

private func compressionPayload(
    source: URL,
    destination: URL
) -> CompressionOperationPayload {
    CompressionOperationPayload(
        sources: [.init(identity: nil, url: source)],
        destination: .init(identity: nil, url: destination),
        formatIdentifier: ArchiveFormat.zip.rawValue,
        compressionLevel: CompressionLevel.normal.rawValue,
        encryptFileNames: false,
        volumeSizeBytes: nil,
        exclusionPatterns: [],
        preserveTimestamps: true,
        conflictPolicy: .replace
    )
}

private func schedulingPolicy(
    global: Int,
    metadata: Int,
    heavyPerVolume: Int
) -> ArchiveResourcePolicy {
    let base = ArchiveResourcePolicy.production
    return ArchiveResourcePolicy(
        listing: base.listing,
        output: base.output,
        process: base.process,
        cache: base.cache,
        split: base.split,
        command: base.command,
        journal: base.journal,
        scheduling: .init(
            globalProcessLimit: global,
            metadataProcessLimit: metadata,
            heavyIOPerVolumeLimit: heavyPerVolume
        )
    )
}

private func progressStream(count: Int) -> AsyncThrowingStream<Double, Error> {
    AsyncThrowingStream { continuation in
        guard count > 0 else {
            continuation.finish()
            return
        }
        for index in 1...count {
            continuation.yield(Double(index) / Double(count))
        }
        continuation.finish()
    }
}

private func gatedProgressStream(
    entered: RuntimeSignal,
    allowFinish: RuntimeGate
) -> AsyncThrowingStream<Double, Error> {
    AsyncThrowingStream { continuation in
        Task {
            await entered.signal()
            await allowFinish.wait()
            continuation.yield(1)
            continuation.finish()
        }
    }
}

private func volumeProvider(
    _ mapping: [URL: UInt64],
    defaultVolume: UInt64 = 99
) -> @Sendable (URL) throws -> UInt64 {
    let standardized = Dictionary(uniqueKeysWithValues: mapping.map {
        ($0.key.standardizedFileURL, $0.value)
    })
    return { url in
        standardized[url.standardizedFileURL] ?? defaultVolume
    }
}

private func collectEvents(
    _ stream: AsyncStream<OperationProgressEvent>
) async -> [OperationProgressEvent] {
    var events: [OperationProgressEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

private func isCancellation(_ task: Task<Void, Error>) async -> Bool {
    do {
        try await task.value
        return false
    } catch is CancellationError {
        return true
    } catch {
        return false
    }
}

private func compressionURLs(_ result: OperationResult?) -> [URL]? {
    guard case let .compression(value)? = result else { return nil }
    return value.finalURLs
}

private func integrityValue(_ result: OperationResult?) -> Bool? {
    guard case let .integrityTest(value)? = result else { return nil }
    return value
}

private func commentValue(_ result: OperationResult?) -> String? {
    guard case let .archiveComment(value)? = result else { return nil }
    return value
}

private func extractionValue(_ result: OperationResult?) -> ExtractionResult? {
    guard case let .extraction(value)? = result else { return nil }
    return value
}

private func archiveFraction(_ event: OperationProgressEvent) -> Double? {
    guard case let .archive(progress) = event else { return nil }
    return progress.fraction
}

private func repackStep(_ event: OperationProgressEvent) -> RepackStep? {
    guard case let .repackStep(step) = event else { return nil }
    return step
}

private func assertRuntimeTrue(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: @escaping @Sendable () async -> Bool
) async {
    let value = await expression()
    XCTAssertTrue(value, file: file, line: line)
}

private func assertRuntimeFalse(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: @escaping @Sendable () async -> Bool
) async {
    let value = await expression()
    XCTAssertFalse(value, file: file, line: line)
}

private func assertRuntimeEqual<T: Equatable & Sendable>(
    _ expected: T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: @escaping @Sendable () async -> T
) async {
    let actual = await expression()
    XCTAssertEqual(actual, expected, file: file, line: line)
}

private func assertRuntimeNil<T: Sendable>(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: @escaping @Sendable () async -> T?
) async {
    let actual = await expression()
    XCTAssertNil(actual, file: file, line: line)
}
