import Darwin
import Foundation
import XCTest
@testable import XZIPCore
import XZIPDomain
@testable import XZIPRuntime

final class ExtractionRecoveryTests: XCTestCase {
    func testActiveArmedSwapBeforeEffectIsNoopAndCleansStaging() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "item", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let locator = try await Task5TestSupport.activate(fixture)
        let handles = try openHandles(fixture, locator: locator)
        defer { handles.close() }
        let replacement = try createFile(
            parent: handles.staging,
            name: "item",
            fileSystem: fixture.fileSystem
        )
        let capturedIdentity = try createExternalFile(
            at: fixture.destinationURL.appendingPathComponent("item"),
            parent: handles.destination,
            fileSystem: fixture.fileSystem
        )
        let capturedNode = try XCTUnwrap(
            fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")
        )
        let captured = try CapturedTreeManifest.capture(
            rootPath: "item",
            rootNode: capturedNode,
            parent: handles.destination,
            fileSystem: fixture.fileSystem,
            listingPolicy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576).listing
        )
        try await fixture.store.armReplaceSwap(
            mutationID: JournalMutationID(rawValue: UUID()),
            staged: try reference(.staging, handles.staging, "item", fixture.fileSystem),
            destination: try reference(.destination, handles.destination, "item", fixture.fileSystem),
            replacementIdentity: replacement,
            expectedCaptured: captured,
            transactionID: fixture.header.transactionID
        )

        let fresh = try freshStore(fixture)
        try await ExtractionRecoveryCoordinator(
            journals: fresh,
            fileSystem: fixture.fileSystem
        ).recoverLiveTransactions()

        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")?.identity,
            capturedIdentity
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Task5TestSupport.rootURL(fixture, locator: locator).path
        ))
        try await assertResolution(fresh, fixture.header.operationID, .absent)
    }

    func testActiveExpectedSwapReversesAndRestoresSubtrees() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "item", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let locator = try await Task5TestSupport.activate(fixture)
        let handles = try openHandles(fixture, locator: locator)
        defer { handles.close() }
        let replacement = try createFile(
            parent: handles.staging,
            name: "item",
            fileSystem: fixture.fileSystem
        )
        let original = try createExternalFile(
            at: fixture.destinationURL.appendingPathComponent("item"),
            parent: handles.destination,
            fileSystem: fixture.fileSystem
        )
        let originalNode = try XCTUnwrap(
            fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")
        )
        let captured = try CapturedTreeManifest.capture(
            rootPath: "item",
            rootNode: originalNode,
            parent: handles.destination,
            fileSystem: fixture.fileSystem,
            listingPolicy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576).listing
        )
        try await fixture.store.armReplaceSwap(
            mutationID: JournalMutationID(rawValue: UUID()),
            staged: try reference(.staging, handles.staging, "item", fixture.fileSystem),
            destination: try reference(.destination, handles.destination, "item", fixture.fileSystem),
            replacementIdentity: replacement,
            expectedCaptured: captured,
            transactionID: fixture.header.transactionID
        )
        _ = try fixture.fileSystem.swapObserved(
            leftParent: handles.staging,
            leftName: "item",
            expectedLeft: replacement,
            rightParent: handles.destination,
            rightName: "item",
            expectedRight: original
        )
        try fixture.fileSystem.fsync(handles.staging)
        try fixture.fileSystem.fsync(handles.destination)

        let fresh = try freshStore(fixture)
        try await ExtractionRecoveryCoordinator(
            journals: fresh,
            fileSystem: fixture.fileSystem
        ).recoverLiveTransactions()

        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")?.identity,
            original
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Task5TestSupport.rootURL(fixture, locator: locator).path
        ))
    }

    func testActiveForeignCaptureReversesForeignWhenDestinationIsReplacement() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "item", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let locator = try await Task5TestSupport.activate(fixture)
        let handles = try openHandles(fixture, locator: locator)
        defer { handles.close() }
        let replacement = try createFile(
            parent: handles.staging,
            name: "item",
            fileSystem: fixture.fileSystem
        )
        let originalURL = fixture.destinationURL.appendingPathComponent("item")
        let detachedOriginalURL = fixture.destinationURL.appendingPathComponent("original-detached")
        _ = try createExternalFile(
            at: originalURL,
            parent: handles.destination,
            fileSystem: fixture.fileSystem
        )
        let originalNode = try XCTUnwrap(
            fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")
        )
        let captured = try CapturedTreeManifest.capture(
            rootPath: "item",
            rootNode: originalNode,
            parent: handles.destination,
            fileSystem: fixture.fileSystem,
            listingPolicy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576).listing
        )
        try await fixture.store.armReplaceSwap(
            mutationID: JournalMutationID(rawValue: UUID()),
            staged: try reference(.staging, handles.staging, "item", fixture.fileSystem),
            destination: try reference(.destination, handles.destination, "item", fixture.fileSystem),
            replacementIdentity: replacement,
            expectedCaptured: captured,
            transactionID: fixture.header.transactionID
        )
        try FileManager.default.moveItem(at: originalURL, to: detachedOriginalURL)
        let foreign = try createExternalFile(
            at: originalURL,
            parent: handles.destination,
            fileSystem: fixture.fileSystem
        )
        _ = try fixture.fileSystem.swapObserved(
            leftParent: handles.staging,
            leftName: "item",
            expectedLeft: replacement,
            rightParent: handles.destination,
            rightName: "item",
            expectedRight: foreign
        )

        let fresh = try freshStore(fixture)
        try await ExtractionRecoveryCoordinator(
            journals: fresh,
            fileSystem: fixture.fileSystem
        ).recoverLiveTransactions()

        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")?.identity,
            foreign
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: detachedOriginalURL.path))
    }

    func testActiveForeignCaptureInverseCrashWindowsResumeWithFreshCoordinator() async throws {
        for boundary in [
            ExtractionRecoveryBoundary.afterInverseRename,
            .afterInverseSourceParentSync,
            .afterInverseDestinationParentSync,
        ] {
            let manifest = StagingCleanupManifest(entries: [
                .init(relativePath: "item", kind: .regularFile),
            ])
            let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
            let locator = try await Task5TestSupport.activate(fixture)
            let handles = try openHandles(fixture, locator: locator)
            defer { handles.close() }
            let replacement = try createFile(
                parent: handles.staging,
                name: "item",
                fileSystem: fixture.fileSystem
            )
            let originalURL = fixture.destinationURL.appendingPathComponent("item")
            let detachedOriginalURL = fixture.destinationURL.appendingPathComponent(
                "original-detached"
            )
            _ = try createExternalFile(
                at: originalURL,
                parent: handles.destination,
                fileSystem: fixture.fileSystem
            )
            let originalNode = try XCTUnwrap(
                fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")
            )
            let captured = try CapturedTreeManifest.capture(
                rootPath: "item",
                rootNode: originalNode,
                parent: handles.destination,
                fileSystem: fixture.fileSystem,
                listingPolicy: Task5TestSupport.policy(
                    maximumJournalBytes: 1_048_576
                ).listing
            )
            try await fixture.store.armReplaceSwap(
                mutationID: JournalMutationID(rawValue: UUID()),
                staged: try reference(.staging, handles.staging, "item", fixture.fileSystem),
                destination: try reference(
                    .destination,
                    handles.destination,
                    "item",
                    fixture.fileSystem
                ),
                replacementIdentity: replacement,
                expectedCaptured: captured,
                transactionID: fixture.header.transactionID
            )
            try FileManager.default.moveItem(at: originalURL, to: detachedOriginalURL)
            let foreign = try createExternalFile(
                at: originalURL,
                parent: handles.destination,
                fileSystem: fixture.fileSystem
            )
            _ = try fixture.fileSystem.swapObserved(
                leftParent: handles.staging,
                leftName: "item",
                expectedLeft: replacement,
                rightParent: handles.destination,
                rightName: "item",
                expectedRight: foreign
            )

            let firstStore = try freshStore(fixture)
            let first = ExtractionRecoveryCoordinator(
                journals: firstStore,
                fileSystem: fixture.fileSystem,
                observer: ThrowOnceRecoveryObserver(boundary)
            )
            await XCTAssertThrowsErrorAsync {
                try await first.recoverLiveTransactions()
            }
            XCTAssertEqual(
                try fixture.fileSystem.statNoFollow(
                    parent: handles.staging,
                    name: "item"
                )?.identity,
                replacement
            )
            XCTAssertEqual(
                try fixture.fileSystem.statNoFollow(
                    parent: handles.destination,
                    name: "item"
                )?.identity,
                foreign
            )

            let recorder = RecordingRecoveryObserver()
            let fresh = try freshStore(fixture)
            try await ExtractionRecoveryCoordinator(
                journals: fresh,
                fileSystem: fixture.fileSystem,
                observer: recorder
            ).recoverLiveTransactions()

            XCTAssertFalse(recorder.boundaries.contains(.afterInverseRename))
            XCTAssertTrue(recorder.boundaries.contains(.afterInverseSourceParentSync))
            XCTAssertTrue(recorder.boundaries.contains(.afterInverseDestinationParentSync))
            XCTAssertTrue(FileManager.default.fileExists(atPath: detachedOriginalURL.path))
            try await assertResolution(fresh, fixture.header.operationID, .absent)
        }
    }

    func testActiveForeignCaptureTornRecoveryProgressFrameResumesBeforeInverse() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "item", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let locator = try await Task5TestSupport.activate(fixture)
        let handles = try openHandles(fixture, locator: locator)
        defer { handles.close() }
        let replacement = try createFile(
            parent: handles.staging,
            name: "item",
            fileSystem: fixture.fileSystem
        )
        let originalURL = fixture.destinationURL.appendingPathComponent("item")
        let detachedOriginalURL = fixture.destinationURL.appendingPathComponent(
            "original-detached"
        )
        _ = try createExternalFile(
            at: originalURL,
            parent: handles.destination,
            fileSystem: fixture.fileSystem
        )
        let originalNode = try XCTUnwrap(
            fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")
        )
        let captured = try CapturedTreeManifest.capture(
            rootPath: "item",
            rootNode: originalNode,
            parent: handles.destination,
            fileSystem: fixture.fileSystem,
            listingPolicy: Task5TestSupport.policy(
                maximumJournalBytes: 1_048_576
            ).listing
        )
        let mutationID = JournalMutationID(rawValue: UUID())
        try await fixture.store.armReplaceSwap(
            mutationID: mutationID,
            staged: try reference(.staging, handles.staging, "item", fixture.fileSystem),
            destination: try reference(
                .destination,
                handles.destination,
                "item",
                fixture.fileSystem
            ),
            replacementIdentity: replacement,
            expectedCaptured: captured,
            transactionID: fixture.header.transactionID
        )
        try FileManager.default.moveItem(at: originalURL, to: detachedOriginalURL)
        let foreign = try createExternalFile(
            at: originalURL,
            parent: handles.destination,
            fileSystem: fixture.fileSystem
        )
        _ = try fixture.fileSystem.swapObserved(
            leftParent: handles.staging,
            leftName: "item",
            expectedLeft: replacement,
            rightParent: handles.destination,
            rightName: "item",
            expectedRight: foreign
        )

        let journalURL = Task5TestSupport.rootURL(
            fixture,
            locator: locator
        ).appendingPathComponent("journal")
        let tearingStore = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem,
            mutationObserver: TearRecoveryProgressFrameObserver(journalURL: journalURL)
        )
        await XCTAssertThrowsErrorAsync {
            try await ExtractionRecoveryCoordinator(
                journals: tearingStore,
                fileSystem: fixture.fileSystem
            ).recoverLiveTransactions()
        }
        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(
                parent: handles.staging,
                name: "item"
            )?.identity,
            foreign
        )
        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(
                parent: handles.destination,
                name: "item"
            )?.identity,
            replacement
        )

        let fresh = try freshStore(fixture)
        try await ExtractionRecoveryCoordinator(
            journals: fresh,
            fileSystem: fixture.fileSystem
        ).recoverLiveTransactions()

        XCTAssertTrue(FileManager.default.fileExists(atPath: detachedOriginalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Task5TestSupport.rootURL(fixture, locator: locator).path
        ))
        try await assertResolution(fresh, fixture.header.operationID, .absent)
    }

    func testActiveForeignCaptureFullUnsyncedProgressReestablishesBarrierBeforeInverse() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "item", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let locator = try await Task5TestSupport.activate(fixture)
        let handles = try openHandles(fixture, locator: locator)
        defer { handles.close() }
        let replacement = try createFile(
            parent: handles.staging,
            name: "item",
            fileSystem: fixture.fileSystem
        )
        let originalURL = fixture.destinationURL.appendingPathComponent("item")
        let detachedOriginalURL = fixture.destinationURL.appendingPathComponent(
            "original-detached"
        )
        _ = try createExternalFile(
            at: originalURL,
            parent: handles.destination,
            fileSystem: fixture.fileSystem
        )
        let originalNode = try XCTUnwrap(
            fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")
        )
        let captured = try CapturedTreeManifest.capture(
            rootPath: "item",
            rootNode: originalNode,
            parent: handles.destination,
            fileSystem: fixture.fileSystem,
            listingPolicy: Task5TestSupport.policy(
                maximumJournalBytes: 1_048_576
            ).listing
        )
        try await fixture.store.armReplaceSwap(
            mutationID: JournalMutationID(rawValue: UUID()),
            staged: try reference(.staging, handles.staging, "item", fixture.fileSystem),
            destination: try reference(
                .destination,
                handles.destination,
                "item",
                fixture.fileSystem
            ),
            replacementIdentity: replacement,
            expectedCaptured: captured,
            transactionID: fixture.header.transactionID
        )
        try FileManager.default.moveItem(at: originalURL, to: detachedOriginalURL)
        let foreign = try createExternalFile(
            at: originalURL,
            parent: handles.destination,
            fileSystem: fixture.fileSystem
        )
        _ = try fixture.fileSystem.swapObserved(
            leftParent: handles.staging,
            leftName: "item",
            expectedLeft: replacement,
            rightParent: handles.destination,
            rightName: "item",
            expectedRight: foreign
        )

        let unsyncedStore = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem,
            mutationObserver: ThrowOnceJournalMutationObserver(
                .recoveryProgressFrameWritten
            )
        )
        await XCTAssertThrowsErrorAsync {
            try await ExtractionRecoveryCoordinator(
                journals: unsyncedStore,
                fileSystem: fixture.fileSystem
            ).recoverLiveTransactions()
        }
        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(
                parent: handles.staging,
                name: "item"
            )?.identity,
            foreign
        )
        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(
                parent: handles.destination,
                name: "item"
            )?.identity,
            replacement
        )

        let barrier = RecordingJournalMutationObserver()
        let barrierStore = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem,
            mutationObserver: barrier
        )
        await XCTAssertThrowsErrorAsync {
            try await ExtractionRecoveryCoordinator(
                journals: barrierStore,
                fileSystem: fixture.fileSystem,
                observer: ThrowOnceRecoveryObserver(.afterInverseRename)
            ).recoverLiveTransactions()
        }
        XCTAssertEqual(
            barrier.events,
            [.journalFileSynced, .transactionRootSynced]
        )
        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(
                parent: handles.staging,
                name: "item"
            )?.identity,
            replacement
        )
        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(
                parent: handles.destination,
                name: "item"
            )?.identity,
            foreign
        )

        let recoveryRecorder = RecordingRecoveryObserver()
        let fresh = try freshStore(fixture)
        try await ExtractionRecoveryCoordinator(
            journals: fresh,
            fileSystem: fixture.fileSystem,
            observer: recoveryRecorder
        ).recoverLiveTransactions()

        XCTAssertFalse(recoveryRecorder.boundaries.contains(.afterInverseRename))
        XCTAssertTrue(recoveryRecorder.boundaries.contains(.afterInverseSourceParentSync))
        XCTAssertTrue(recoveryRecorder.boundaries.contains(.afterInverseDestinationParentSync))
        XCTAssertTrue(FileManager.default.fileExists(atPath: detachedOriginalURL.path))
        try await assertResolution(fresh, fixture.header.operationID, .absent)
    }

    func testActiveForeignCaptureWithOccupiedPublicPathPreservesAllNodes() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "item", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let locator = try await Task5TestSupport.activate(fixture)
        let handles = try openHandles(fixture, locator: locator)
        defer { handles.close() }
        let replacement = try createFile(
            parent: handles.staging,
            name: "item",
            fileSystem: fixture.fileSystem
        )
        let itemURL = fixture.destinationURL.appendingPathComponent("item")
        let originalDetached = fixture.destinationURL.appendingPathComponent("original-detached")
        let replacementDetached = fixture.destinationURL.appendingPathComponent("replacement-detached")
        _ = try createExternalFile(at: itemURL, parent: handles.destination, fileSystem: fixture.fileSystem)
        let originalNode = try XCTUnwrap(
            fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")
        )
        let captured = try CapturedTreeManifest.capture(
            rootPath: "item",
            rootNode: originalNode,
            parent: handles.destination,
            fileSystem: fixture.fileSystem,
            listingPolicy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576).listing
        )
        try await fixture.store.armReplaceSwap(
            mutationID: JournalMutationID(rawValue: UUID()),
            staged: try reference(.staging, handles.staging, "item", fixture.fileSystem),
            destination: try reference(.destination, handles.destination, "item", fixture.fileSystem),
            replacementIdentity: replacement,
            expectedCaptured: captured,
            transactionID: fixture.header.transactionID
        )
        try FileManager.default.moveItem(at: itemURL, to: originalDetached)
        let foreign = try createExternalFile(at: itemURL, parent: handles.destination, fileSystem: fixture.fileSystem)
        _ = try fixture.fileSystem.swapObserved(
            leftParent: handles.staging,
            leftName: "item",
            expectedLeft: replacement,
            rightParent: handles.destination,
            rightName: "item",
            expectedRight: foreign
        )
        try FileManager.default.moveItem(at: itemURL, to: replacementDetached)
        let occupied = try createExternalFile(
            at: itemURL,
            parent: handles.destination,
            fileSystem: fixture.fileSystem
        )

        let fresh = try freshStore(fixture)
        await XCTAssertThrowsErrorAsync {
            try await ExtractionRecoveryCoordinator(
                journals: fresh,
                fileSystem: fixture.fileSystem
            ).recoverLiveTransactions()
        }

        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(parent: handles.staging, name: "item")?.identity,
            foreign
        )
        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")?.identity,
            occupied
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalDetached.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementDetached.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Task5TestSupport.rootURL(fixture, locator: locator).path
        ))
    }

    func testActiveAppliedPublishMoveReversesAndReleases() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "published", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let locator = try await Task5TestSupport.activate(fixture)
        let handles = try openHandles(fixture, locator: locator)
        defer { handles.close() }
        let identity = try createFile(
            parent: handles.staging,
            name: "published",
            fileSystem: fixture.fileSystem
        )
        let staged = try reference(
            .staging,
            handles.staging,
            "published",
            fixture.fileSystem
        )
        let destination = try reference(
            .destination,
            handles.destination,
            "published",
            fixture.fileSystem
        )
        try await fixture.store.armPublishMove(
            mutationID: JournalMutationID(rawValue: UUID()),
            staged: staged,
            destination: destination,
            publishedIdentity: identity,
            transactionID: fixture.header.transactionID
        )
        let forward = try fixture.fileSystem.moveExclusiveObserved(
            fromParent: handles.staging,
            fromName: "published",
            toParent: handles.destination,
            toName: "published",
            expectedSource: identity
        )
        XCTAssertNil(forward.sourceIdentity)
        XCTAssertEqual(forward.destinationIdentity, identity)

        try await recover(fixture)

        XCTAssertNil(try fixture.fileSystem.statNoFollow(
            parent: handles.destination,
            name: "published"
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Task5TestSupport.rootURL(fixture, locator: locator).path
        ))
        try await assertResolution(
            fixture.store,
            fixture.header.operationID,
            .absent
        )
    }

    func testActivePublishMovePreEffectAndCollisionAreNoEffect() async throws {
        for collision in [false, true] {
            let manifest = StagingCleanupManifest(entries: [
                .init(relativePath: "item", kind: .regularFile),
            ])
            let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
            let locator = try await Task5TestSupport.activate(fixture)
            let handles = try openHandles(fixture, locator: locator)
            let identity = try createFile(
                parent: handles.staging,
                name: "item",
                fileSystem: fixture.fileSystem
            )
            try await fixture.store.armPublishMove(
                mutationID: JournalMutationID(rawValue: UUID()),
                staged: try reference(
                    .staging,
                    handles.staging,
                    "item",
                    fixture.fileSystem
                ),
                destination: try reference(
                    .destination,
                    handles.destination,
                    "item",
                    fixture.fileSystem
                ),
                publishedIdentity: identity,
                transactionID: fixture.header.transactionID
            )
            if collision {
                _ = try createExternalFile(
                    at: fixture.destinationURL.appendingPathComponent("item"),
                    parent: handles.destination,
                    fileSystem: fixture.fileSystem
                )
            }

            try await recover(fixture)

            if collision {
                XCTAssertNotNil(try fixture.fileSystem.statNoFollow(
                    parent: handles.destination,
                    name: "item"
                ))
            }
            try await assertResolution(
                fixture.store,
                fixture.header.operationID,
                .absent
            )
            handles.close()
        }
    }

    func testActivePublishMoveInverseCrashWindowsResumeWithoutSecondRename() async throws {
        for boundary in [
            ExtractionRecoveryBoundary.afterInverseRename,
            .afterInverseSourceParentSync,
            .afterInverseDestinationParentSync,
            .afterInverseTargetVerification,
        ] {
            let manifest = StagingCleanupManifest(entries: [
                .init(relativePath: "published", kind: .regularFile),
            ])
            let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
            let locator = try await Task5TestSupport.activate(fixture)
            let handles = try openHandles(fixture, locator: locator)
            let identity = try createFile(
                parent: handles.staging,
                name: "published",
                fileSystem: fixture.fileSystem
            )
            let staged = try reference(
                .staging,
                handles.staging,
                "published",
                fixture.fileSystem
            )
            let destination = try reference(
                .destination,
                handles.destination,
                "published",
                fixture.fileSystem
            )
            try await fixture.store.armPublishMove(
                mutationID: JournalMutationID(rawValue: UUID()),
                staged: staged,
                destination: destination,
                publishedIdentity: identity,
                transactionID: fixture.header.transactionID
            )
            _ = try fixture.fileSystem.moveExclusiveObserved(
                fromParent: handles.staging,
                fromName: "published",
                toParent: handles.destination,
                toName: "published",
                expectedSource: identity
            )

            let first = ExtractionRecoveryCoordinator(
                journals: fixture.store,
                fileSystem: fixture.fileSystem,
                observer: ThrowOnceRecoveryObserver(boundary)
            )
            await XCTAssertThrowsErrorAsync {
                try await first.recoverLiveTransactions()
            }
            XCTAssertEqual(try fixture.fileSystem.statNoFollow(
                parent: handles.staging,
                name: "published"
            )?.identity, identity)
            XCTAssertNil(try fixture.fileSystem.statNoFollow(
                parent: handles.destination,
                name: "published"
            ))

            let recorder = RecordingRecoveryObserver()
            let fresh = try freshStore(fixture)
            try await ExtractionRecoveryCoordinator(
                journals: fresh,
                fileSystem: fixture.fileSystem,
                observer: recorder
            ).recoverLiveTransactions()
            XCTAssertFalse(recorder.boundaries.contains(.afterInverseRename))
            try await assertResolution(
                fresh,
                fixture.header.operationID,
                .absent
            )
            handles.close()
        }
    }

    func testActivePublishMoveForeignCaptureIsRestoredAndEvidenceRetained() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "published", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let locator = try await Task5TestSupport.activate(fixture)
        let handles = try openHandles(fixture, locator: locator)
        defer { handles.close() }
        let identity = try createFile(
            parent: handles.staging,
            name: "published",
            fileSystem: fixture.fileSystem
        )
        try await fixture.store.armPublishMove(
            mutationID: JournalMutationID(rawValue: UUID()),
            staged: try reference(
                .staging,
                handles.staging,
                "published",
                fixture.fileSystem
            ),
            destination: try reference(
                .destination,
                handles.destination,
                "published",
                fixture.fileSystem
            ),
            publishedIdentity: identity,
            transactionID: fixture.header.transactionID
        )
        _ = try fixture.fileSystem.moveExclusiveObserved(
            fromParent: handles.staging,
            fromName: "published",
            toParent: handles.destination,
            toName: "published",
            expectedSource: identity
        )
        let probe = RecoveryExclusiveRenameProbe(
            injectedName: "published",
            detachedName: "published-detached",
            occupyAfterExchange: false
        )
        let recoveryFileSystem = DarwinFileSystemOperations(
            exclusiveRename: probe.call,
            exchangeRename: {
                renameatx_np($0, $1, $2, $3, UInt32(RENAME_SWAP))
            }
        )
        let fresh = try freshStore(fixture)

        await XCTAssertThrowsErrorAsync {
            try await ExtractionRecoveryCoordinator(
                journals: fresh,
                fileSystem: recoveryFileSystem
            ).recoverLiveTransactions()
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.destinationURL.appendingPathComponent("published")),
            Data("foreign".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.destinationURL.appendingPathComponent("published-detached")),
            Data("published".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Task5TestSupport.rootURL(fixture, locator: locator).path
        ))
        try await assertResolution(fresh, fixture.header.operationID, .unfinished)
    }

    func testActivePublishMoveForeignCaptureWithOccupiedDestinationPreservesAllEvidence() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "published", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let locator = try await Task5TestSupport.activate(fixture)
        let handles = try openHandles(fixture, locator: locator)
        defer { handles.close() }
        let identity = try createFile(
            parent: handles.staging,
            name: "published",
            fileSystem: fixture.fileSystem
        )
        try await fixture.store.armPublishMove(
            mutationID: JournalMutationID(rawValue: UUID()),
            staged: try reference(
                .staging,
                handles.staging,
                "published",
                fixture.fileSystem
            ),
            destination: try reference(
                .destination,
                handles.destination,
                "published",
                fixture.fileSystem
            ),
            publishedIdentity: identity,
            transactionID: fixture.header.transactionID
        )
        _ = try fixture.fileSystem.moveExclusiveObserved(
            fromParent: handles.staging,
            fromName: "published",
            toParent: handles.destination,
            toName: "published",
            expectedSource: identity
        )
        let probe = RecoveryExclusiveRenameProbe(
            injectedName: "published",
            detachedName: "published-detached",
            occupyAfterExchange: true
        )
        let recoveryFileSystem = DarwinFileSystemOperations(
            exclusiveRename: probe.call,
            exchangeRename: {
                renameatx_np($0, $1, $2, $3, UInt32(RENAME_SWAP))
            }
        )
        let fresh = try freshStore(fixture)

        await XCTAssertThrowsErrorAsync {
            try await ExtractionRecoveryCoordinator(
                journals: fresh,
                fileSystem: recoveryFileSystem
            ).recoverLiveTransactions()
        }

        let rootURL = Task5TestSupport.rootURL(fixture, locator: locator)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destinationURL.appendingPathComponent("published")),
            Data("occupied".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: rootURL.appendingPathComponent("staging/published")),
            Data("foreign".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.destinationURL.appendingPathComponent("published-detached")),
            Data("published".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))
        try await assertResolution(fresh, fixture.header.operationID, .unfinished)
    }

    func testCommittedSwapCleanupNeedsNoBackupCapability() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "item", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let locator = try await Task5TestSupport.activate(fixture)
        let handles = try openHandles(fixture, locator: locator)
        defer { handles.close() }
        let replacement = try createFile(
            parent: handles.staging,
            name: "item",
            fileSystem: fixture.fileSystem
        )
        let itemURL = fixture.destinationURL.appendingPathComponent("item")
        _ = try createExternalFile(
            at: itemURL,
            parent: handles.destination,
            fileSystem: fixture.fileSystem
        )
        let originalNode = try XCTUnwrap(
            fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")
        )
        let captured = try CapturedTreeManifest.capture(
            rootPath: "item",
            rootNode: originalNode,
            parent: handles.destination,
            fileSystem: fixture.fileSystem,
            listingPolicy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576).listing
        )
        try await fixture.store.armReplaceSwap(
            mutationID: JournalMutationID(rawValue: UUID()),
            staged: try reference(.staging, handles.staging, "item", fixture.fileSystem),
            destination: try reference(.destination, handles.destination, "item", fixture.fileSystem),
            replacementIdentity: replacement,
            expectedCaptured: captured,
            transactionID: fixture.header.transactionID
        )
        _ = try fixture.fileSystem.swapObserved(
            leftParent: handles.staging,
            leftName: "item",
            expectedLeft: replacement,
            rightParent: handles.destination,
            rightName: "item",
            expectedRight: originalNode.identity
        )
        try fixture.fileSystem.fsync(handles.staging)
        try fixture.fileSystem.fsync(handles.destination)
        try await fixture.store.markCommitted(
            transactionID: fixture.header.transactionID,
            result: Task5TestSupport.result(fixture)
        )
        let detached = fixture.destinationURL.appendingPathComponent("replacement-detached")
        try FileManager.default.moveItem(at: itemURL, to: detached)
        try Data("foreign".utf8).write(to: itemURL)

        let fresh = try freshStore(fixture)
        try await ExtractionRecoveryCoordinator(
            journals: fresh,
            fileSystem: fixture.fileSystem
        ).recoverLiveTransactions()

        XCTAssertEqual(try Data(contentsOf: itemURL), Data("foreign".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: detached.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Task5TestSupport.rootURL(fixture, locator: locator).path
        ))
        guard case .committed = try await fresh.resolution(for: fixture.header.operationID) else {
            return XCTFail("Expected committed resolution")
        }
    }

    func testReservedAndRootCreatedRecoveryCleanOnlyExactSafeRoots() async throws {
        let reserved = try await Task5TestSupport.makeFixture(self)
        _ = try await reserved.store.register(transaction: reserved.header, namespace: reserved.namespace)
        try await recover(reserved)
        try await assertResolution(reserved.store, reserved.header.operationID, .absent)

        let partial = try await Task5TestSupport.makeFixture(self)
        let reservation = try await partial.store.register(transaction: partial.header, namespace: partial.namespace)
        _ = try await partial.store.createTransactionRoot(reservation)
        _ = try await partial.store.activate(reservation)
        try await partial.store.markRolledBack(partial.header.transactionID)

        try await recover(partial)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: partial.namespace.url.appendingPathComponent(reservation.rootName).path
        ))
        try await assertResolution(partial.store, partial.header.operationID, .absent)
    }


    func testRolledBackCleanupDirectRemovalBoundariesResumeForEveryComponent() async throws {
        let boundaries: [FileSystemOperationBoundary] = [
            .afterOwnedFinalVerification,
            .afterOwnedDirectRemoval,
            .afterOwnedParentSync,
        ]
        for component in ["journal", "staging", "root"] {
            for boundary in boundaries {
                let observer = ThrowOnceComponentObserver(
                    boundary: boundary,
                    matches: { observed in
                        component == "root"
                            ? observed.hasPrefix("transaction-")
                            : observed == component
                    }
                )
                let fixture = try await Task5TestSupport.makeFixture(
                    self,
                    operationObserver: observer
                )
                let locator = try await Task5TestSupport.activate(fixture)
                try await fixture.store.markRolledBack(
                    fixture.header.transactionID
                )

                let first = ExtractionRecoveryCoordinator(
                    journals: fixture.store,
                    fileSystem: fixture.fileSystem
                )
                await XCTAssertThrowsErrorAsync {
                    try await first.recoverLiveTransactions()
                }

                let parent: DirectoryHandle
                let expectedName: String
                if component == "root" {
                    parent = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
                        at: fixture.namespace.url,
                        expected: fixture.namespace.identity
                    )
                    expectedName = locator.rootName
                } else {
                    parent = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
                        at: Task5TestSupport.rootURL(fixture, locator: locator),
                        expected: locator.rootIdentity
                    )
                    expectedName = component
                }
                let observed = try fixture.fileSystem.statNoFollow(
                    parent: parent,
                    name: expectedName
                )
                parent.close()
                XCTAssertEqual(
                    observed != nil,
                    boundary == .afterOwnedFinalVerification,
                    "\(component) at \(boundary)"
                )

                let fresh = try freshStore(fixture)
                let resumed = ExtractionRecoveryCoordinator(
                    journals: fresh,
                    fileSystem: fixture.fileSystem
                )
                try await resumed.recoverLiveTransactions()
                let resolution = try await fresh.resolution(
                    for: fixture.header.operationID
                )
                XCTAssertEqual(resolution, .absent)
            }
        }
    }

    func testCommittedCleanupDirectRemovalBoundariesResumeForEveryComponent() async throws {
        let boundaries: [FileSystemOperationBoundary] = [
            .afterOwnedFinalVerification,
            .afterOwnedDirectRemoval,
            .afterOwnedParentSync,
        ]
        for component in ["journal", "staging", "root"] {
            for boundary in boundaries {
                let fixture = try await makeCommittedEmptyFixture()
                let observer = ThrowOnceComponentObserver(
                    boundary: boundary,
                    matches: { observed in
                        component == "root"
                            ? observed == fixture.locator.rootName
                            : observed == component
                    }
                )
                let crashing = DarwinFileSystemOperations(
                    operationObserver: observer
                )
                let firstStore = TransactionJournalStore(
                    indexDirectory: fixture.fixture.indexDirectory,
                    indexFileName: "extraction-index.json",
                    policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
                    fileSystem: crashing
                )
                let first = ExtractionRecoveryCoordinator(
                    journals: firstStore,
                    fileSystem: crashing
                )
                await XCTAssertThrowsErrorAsync {
                    try await first.recoverLiveTransactions()
                }

                let parent: DirectoryHandle
                let expectedName: String
                if component == "root" {
                    parent = try fixture.fixture.fileSystem
                        .openTransactionOwnedDirectoryNoFollow(
                            at: fixture.fixture.namespace.url,
                            expected: fixture.fixture.namespace.identity
                        )
                    expectedName = fixture.locator.rootName
                } else {
                    parent = try fixture.fixture.fileSystem
                        .openTransactionOwnedDirectoryNoFollow(
                            at: fixture.rootURL,
                            expected: fixture.locator.rootIdentity
                        )
                    expectedName = component
                }
                let observed = try fixture.fixture.fileSystem.statNoFollow(
                    parent: parent,
                    name: expectedName
                )
                parent.close()
                XCTAssertEqual(
                    observed != nil,
                    boundary == .afterOwnedFinalVerification,
                    "\(component) at \(boundary)"
                )

                let fresh = try freshStore(fixture.fixture)
                let resumed = ExtractionRecoveryCoordinator(
                    journals: fresh,
                    fileSystem: fixture.fixture.fileSystem
                )
                try await resumed.recoverLiveTransactions()
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: fixture.rootURL.path)
                )
                try await assertResolution(
                    fresh,
                    fixture.fixture.header.operationID,
                    .committed
                )
            }
        }
    }

    func testCommittedRootAbsentRepeatedRestartNeverOpensJournal() async throws {
        let fixture = try await makeCommittedEmptyFixture()
        try await recover(fixture.fixture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL.path))

        try await recover(fixture.fixture)
        try await recover(fixture.fixture)

        try await assertResolution(
            fixture.fixture.store,
            fixture.fixture.header.operationID,
            .committed
        )
    }

    func testCommittedRootPresentMalformedOrTruncatedAuthorityFailsClosed() async throws {
        let fixture = try await makeCommittedEmptyFixture()
        let journal = fixture.rootURL.appendingPathComponent("journal")
        let append = try FileHandle(forWritingTo: journal)
        try append.seekToEnd()
        try append.write(contentsOf: Data([1, 2, 3, 4]))
        try append.close()

        await XCTAssertThrowsErrorAsync { try await self.recover(fixture.fixture) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        try await assertResolution(
            fixture.fixture.store,
            fixture.fixture.header.operationID,
            .committed
        )
    }

    func testCommittedFreshStoreJournalAbsentEmptyInfrastructureResumesPostAuthorityCleanup() async throws {
        let fixture = try await makeCommittedEmptyFixture()
        try removeJournal(fixture)
        let fresh = try freshStore(fixture.fixture)

        try await ExtractionRecoveryCoordinator(
            journals: fresh,
            fileSystem: fixture.fixture.fileSystem
        ).recoverLiveTransactions()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL.path))
        try await assertResolution(fresh, fixture.fixture.header.operationID, .committed)
    }

    func testCommittedFreshStoreJournalAbsentNonEmptyStagingOrRemainingManifestNodeFailsClosed() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "remaining", kind: .regularFile),
        ])
        let fixture = try await makeCommittedEmptyFixture(manifest: manifest)
        try removeJournal(fixture)
        let root = try fixture.fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: fixture.rootURL,
            expected: fixture.locator.rootIdentity
        )
        let staging = try fixture.fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: root,
            name: "staging",
            expected: nil
        )
        _ = try createFile(parent: staging, name: "remaining", fileSystem: fixture.fixture.fileSystem)
        staging.close()
        root.close()

        await XCTAssertThrowsErrorAsync { try await self.recover(fixture.fixture) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rootURL.path))
    }

    func testCommittedFreshStoreJournalAbsentIdentityKindModeMismatchOrUnexpectedRootEntryFailsClosed() async throws {
        let fixture = try await makeCommittedEmptyFixture()
        try removeJournal(fixture)
        try Data("unexpected".utf8).write(to: fixture.rootURL.appendingPathComponent("extra"))

        await XCTAssertThrowsErrorAsync { try await self.recover(fixture.fixture) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rootURL.appendingPathComponent("extra").path))
        try await assertResolution(
            fixture.fixture.store,
            fixture.fixture.header.operationID,
            .committed
        )
    }

    func testCommittedPostAuthorityCrashAfterJournalUnlinkBeforeRootFsyncResumes() async throws {
        let fixture = try await makeCommittedEmptyFixture()
        try removeJournal(fixture)

        try await recover(fixture.fixture)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL.path))
        try await assertResolution(
            fixture.fixture.store,
            fixture.fixture.header.operationID,
            .committed
        )
    }

    func testCommittedPostAuthorityCrashAfterRootFsyncBeforeInfrastructureOrRootRemovalResumes() async throws {
        let fixture = try await makeCommittedEmptyFixture()
        try removeJournal(fixture)
        let root = try fixture.fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: fixture.rootURL,
            expected: fixture.locator.rootIdentity
        )
        try fixture.fixture.fileSystem.fsync(root)
        root.close()

        try await recover(fixture.fixture)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL.path))
    }

    func testCommittedJournalAbsentPathsNeverAccessDestinationEffects() async throws {
        let fixture = try await makeCommittedEmptyFixture()
        try removeJournal(fixture)
        let movedDestination = fixture.fixture.root.appendingPathComponent("moved-destination", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.fixture.destinationURL, to: movedDestination)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.fixture.destinationURL.path,
            withDestinationPath: movedDestination.path
        )

        try await recover(fixture.fixture)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedDestination.path))
    }


    func testAbortPreparationReservedAbsentRootFsyncsNamespaceThenReleases() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let fileSystem = JournalTestFileSystem(base: fixture.fileSystem)
        let store = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fileSystem
        )
        let reservation = try await store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        try await store.relinquishPreparation(reservation)
        let rootURL = fixture.namespace.url.appendingPathComponent(
            reservation.rootName,
            isDirectory: true
        )
        let recovery = ExtractionRecoveryCoordinator(
            journals: store,
            fileSystem: fileSystem
        )

        fileSystem.resetObservations()
        fileSystem.failNextDirectoryFsync()
        await XCTAssertThrowsErrorAsync {
            try await recovery.abortPreparation(
                transactionID: fixture.header.transactionID
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
        let retained = try await store.liveTransactions()
        XCTAssertEqual(retained.first?.phase, .reserved)

        try await recovery.abortPreparation(
            transactionID: fixture.header.transactionID
        )
        let remaining = try await store.liveTransactions()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAbortPreparationReservedEmptyRootRemovesThenReleases() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let fileSystem = JournalTestFileSystem(base: fixture.fileSystem)
        let store = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fileSystem
        )
        let reservation = try await store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        fileSystem.failNextDirectoryFsync()
        await XCTAssertThrowsErrorAsync {
            _ = try await store.createTransactionRoot(reservation)
        }
        try await store.relinquishPreparation(reservation)
        let rootURL = fixture.namespace.url.appendingPathComponent(
            reservation.rootName,
            isDirectory: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))
        let recovery = ExtractionRecoveryCoordinator(
            journals: store,
            fileSystem: fileSystem
        )

        fileSystem.resetObservations()
        fileSystem.failNextDirectoryFsync()
        await XCTAssertThrowsErrorAsync {
            try await recovery.abortPreparation(
                transactionID: fixture.header.transactionID
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))
        let retained = try await store.liveTransactions()
        XCTAssertEqual(retained.first?.phase, .reserved)

        try await recovery.abortPreparation(
            transactionID: fixture.header.transactionID
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
        let remaining = try await store.liveTransactions()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAbortPreparationRootCreatedPartialInfrastructureResumesThenReleases() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let fileSystem = JournalTestFileSystem(base: fixture.fileSystem)
        let store = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fileSystem
        )
        let reservation = try await store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        _ = try await store.createTransactionRoot(reservation)
        fileSystem.failNextTransactionOpen(named: "staging")
        await XCTAssertThrowsErrorAsync {
            _ = try await store.activate(reservation)
        }
        let interrupted = try await store.liveTransactions()
        XCTAssertEqual(interrupted.first?.phase, .rootCreated)

        try await store.relinquishPreparation(reservation)
        let recovery = ExtractionRecoveryCoordinator(
            journals: store,
            fileSystem: fileSystem
        )
        try await recovery.abortPreparation(
            transactionID: fixture.header.transactionID
        )

        let rootURL = fixture.namespace.url.appendingPathComponent(
            reservation.rootName,
            isDirectory: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
        let remaining = try await store.liveTransactions()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAbortPreparationRejectsActiveRolledBackAndCommittedWithoutMutation() async throws {
        for phase in [
            TransactionRecoveryPhase.active,
            .rolledBack,
            .committed,
        ] {
            let fixture = try await Task5TestSupport.makeFixture(self)
            let locator = try await Task5TestSupport.activate(fixture)
            switch phase {
            case .rolledBack:
                try await fixture.store.markRolledBack(
                    fixture.header.transactionID
                )
            case .committed:
                try await fixture.store.markCommitted(
                    transactionID: fixture.header.transactionID,
                    result: Task5TestSupport.result(fixture)
                )
            case .active:
                break
            case .reserved, .rootCreated:
                XCTFail("Unexpected test phase")
            }
            let indexURL = fixture.namespace.url.appendingPathComponent(
                "extraction-index.json"
            )
            let rootURL = Task5TestSupport.rootURL(
                fixture,
                locator: locator
            )
            let indexBefore = try Data(contentsOf: indexURL)
            let namesBefore = try FileManager.default.contentsOfDirectory(
                atPath: rootURL.path
            ).sorted()
            let recovery = ExtractionRecoveryCoordinator(
                journals: fixture.store,
                fileSystem: fixture.fileSystem
            )

            await XCTAssertThrowsErrorAsync {
                try await recovery.abortPreparation(
                    transactionID: fixture.header.transactionID
                )
            }

            XCTAssertEqual(try Data(contentsOf: indexURL), indexBefore)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: rootURL.path
                ).sorted(),
                namesBefore
            )
            let live = try await fixture.store.liveTransactions()
            XCTAssertEqual(live.first?.phase, phase)
        }

        let rootCreatedFixture = try await Task5TestSupport.makeFixture(self)
        let rootCreatedFileSystem = JournalTestFileSystem(
            base: rootCreatedFixture.fileSystem
        )
        let rootCreatedStore = TransactionJournalStore(
            indexDirectory: rootCreatedFixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: rootCreatedFileSystem
        )
        let rootCreatedReservation = try await rootCreatedStore.register(
            transaction: rootCreatedFixture.header,
            namespace: rootCreatedFixture.namespace
        )
        _ = try await rootCreatedStore.createTransactionRoot(
            rootCreatedReservation
        )
        rootCreatedFileSystem.failNextTransactionOpen(named: "staging")
        await XCTAssertThrowsErrorAsync {
            _ = try await rootCreatedStore.activate(rootCreatedReservation)
        }
        let rootCreated = try await rootCreatedStore.liveTransactions()
        XCTAssertEqual(rootCreated.first?.phase, .rootCreated)
        try await rootCreatedStore.relinquishPreparation(
            rootCreatedReservation
        )

        let rootCreatedGate = rootCreatedFileSystem.blockNextStat(
            named: rootCreatedReservation.rootName
        )
        let rootCreatedRecovery = ExtractionRecoveryCoordinator(
            journals: rootCreatedStore,
            fileSystem: rootCreatedFileSystem
        )
        let rootCreatedAbort = Task {
            try await rootCreatedRecovery.abortPreparation(
                transactionID: rootCreatedFixture.header.transactionID
            )
        }
        XCTAssertEqual(
            rootCreatedGate.waitUntilBlocked(timeout: .now() + 2),
            .success
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await rootCreatedStore.activate(rootCreatedReservation)
        }
        rootCreatedGate.release()
        try await rootCreatedAbort.value
        let rootCreatedRemaining = try await rootCreatedStore.liveTransactions()
        XCTAssertTrue(rootCreatedRemaining.isEmpty)

        let preparationFixture = try await Task5TestSupport.makeFixture(self)
        let preparationStore = preparationFixture.store
        let preparationReservation = try await preparationStore.register(
            transaction: preparationFixture.header,
            namespace: preparationFixture.namespace
        )
        let preparationRecovery = ExtractionRecoveryCoordinator(
            journals: preparationStore,
            fileSystem: preparationFixture.fileSystem
        )
        await XCTAssertThrowsErrorAsync {
            try await preparationRecovery.abortPreparation(
                transactionID: preparationFixture.header.transactionID
            )
        }
        _ = try await preparationStore.createTransactionRoot(
            preparationReservation
        )
        let preparationOwner = try await preparationStore.activate(
            preparationReservation
        )
        preparationOwner.close()
        let preparationLive = try await preparationStore.liveTransactions()
        XCTAssertEqual(preparationLive.first?.phase, .active)

        let abortFixture = try await Task5TestSupport.makeFixture(self)
        let abortFileSystem = JournalTestFileSystem(base: abortFixture.fileSystem)
        let abortStore = TransactionJournalStore(
            indexDirectory: abortFixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: abortFileSystem
        )
        let abortReservation = try await abortStore.register(
            transaction: abortFixture.header,
            namespace: abortFixture.namespace
        )
        try await abortStore.relinquishPreparation(abortReservation)
        let abortGate = abortFileSystem.blockNextStatAfterResult(
            named: abortReservation.rootName
        )
        let abortRecovery = ExtractionRecoveryCoordinator(
            journals: abortStore,
            fileSystem: abortFileSystem
        )
        let abortTask = Task {
            try await abortRecovery.abortPreparation(
                transactionID: abortFixture.header.transactionID
            )
        }
        XCTAssertEqual(
            abortGate.waitUntilBlocked(timeout: .now() + 2),
            .success
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await abortStore.createTransactionRoot(abortReservation)
        }
        abortGate.release()
        try await abortTask.value
        let abortRemaining = try await abortStore.liveTransactions()
        XCTAssertTrue(abortRemaining.isEmpty)
        let abortNamespace = try abortFileSystem
            .openTransactionOwnedDirectoryNoFollow(
                at: abortFixture.namespace.url,
                expected: abortFixture.namespace.identity
            )
        XCTAssertNil(
            try abortFileSystem.statNoFollow(
                parent: abortNamespace,
                name: abortReservation.rootName
            )
        )
        abortNamespace.close()

        let cancellationFixture = try await Task5TestSupport.makeFixture(self)
        let cancellationStore = cancellationFixture.store
        let cancellationReservation = try await cancellationStore.register(
            transaction: cancellationFixture.header,
            namespace: cancellationFixture.namespace
        )
        _ = try await cancellationStore.createTransactionRoot(
            cancellationReservation
        )
        let cancellationRecovery = ExtractionRecoveryCoordinator(
            journals: cancellationStore,
            fileSystem: cancellationFixture.fileSystem
        )
        let cancellationGate = FileSystemCallGate()
        let cancellationTask = Task {
            cancellationGate.block()
            do {
                try Task.checkCancellation()
                _ = try await cancellationStore.activate(
                    cancellationReservation
                )
            } catch {
                try await cancellationStore.relinquishPreparation(
                    cancellationReservation
                )
                try await cancellationRecovery.abortPreparation(
                    transactionID: cancellationFixture.header.transactionID
                )
                throw error
            }
        }
        XCTAssertEqual(
            cancellationGate.waitUntilBlocked(timeout: .now() + 2),
            .success
        )
        cancellationTask.cancel()
        cancellationGate.release()
        await XCTAssertThrowsErrorAsync {
            try await cancellationTask.value
        }
        let cancellationRemaining = try await cancellationStore.liveTransactions()
        XCTAssertTrue(cancellationRemaining.isEmpty)
        let cancellationNamespace = try cancellationFixture.fileSystem
            .openTransactionOwnedDirectoryNoFollow(
                at: cancellationFixture.namespace.url,
                expected: cancellationFixture.namespace.identity
            )
        XCTAssertNil(
            try cancellationFixture.fileSystem.statNoFollow(
                parent: cancellationNamespace,
                name: cancellationReservation.rootName
            )
        )
        cancellationNamespace.close()
    }

    func testFinalizeCommittedCleansBeforeReleaseAndIsAbsentIdempotent() async throws {
        let committed = try await makeCommittedEmptyFixture()
        let destinationHandle = try committed.fixture.fileSystem.openDirectoryNoFollow(
            at: committed.fixture.destinationURL
        )
        let destinationIdentity = try committed.fixture.fileSystem.identity(
            of: destinationHandle
        )
        destinationHandle.close()
        let recovery = ExtractionRecoveryCoordinator(
            journals: committed.fixture.store,
            fileSystem: committed.fixture.fileSystem
        )

        try await recovery.finalizeCommittedExtraction(
            operationID: committed.fixture.header.operationID
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.rootURL.path))
        try await assertResolution(
            committed.fixture.store,
            committed.fixture.header.operationID,
            .absent
        )
        try await recovery.finalizeCommittedExtraction(
            operationID: committed.fixture.header.operationID
        )
        let reopenedDestination = try committed.fixture.fileSystem.openDirectoryNoFollow(
            at: committed.fixture.destinationURL
        )
        XCTAssertEqual(
            try committed.fixture.fileSystem.identity(of: reopenedDestination),
            destinationIdentity
        )
        reopenedDestination.close()
    }

    func testFinalizeCommittedFailurePreservesMarkerAndArtifacts() async throws {
        let cleanupFailure = try await makeCommittedEmptyFixture()
        let cleanupIndexURL = cleanupFailure.fixture.namespace.url
            .appendingPathComponent("extraction-index.json")
        let cleanupIndexBefore = try Data(contentsOf: cleanupIndexURL)
        let destination = try cleanupFailure.fixture.fileSystem.openDirectoryNoFollow(
            at: cleanupFailure.fixture.destinationURL
        )
        let destinationIdentity = try cleanupFailure.fixture.fileSystem.identity(
            of: destination
        )
        destination.close()
        let root = try cleanupFailure.fixture.fileSystem
            .openTransactionOwnedDirectoryNoFollow(
                at: cleanupFailure.rootURL,
                expected: cleanupFailure.locator.rootIdentity
            )
        let staging = try cleanupFailure.fixture.fileSystem
            .openTransactionOwnedDirectoryNoFollow(
                parent: root,
                name: "staging",
                expected: nil
            )
        let unexpected = try cleanupFailure.fixture.fileSystem
            .createRegularFileExclusive(
                parent: staging,
                name: "unexpected"
            )
        try unexpected.write(Data("unexpected".utf8))
        try unexpected.fsync()
        unexpected.close()
        try cleanupFailure.fixture.fileSystem.fsync(staging)
        try cleanupFailure.fixture.fileSystem.fsync(root)
        staging.close()
        root.close()
        let cleanupRecovery = ExtractionRecoveryCoordinator(
            journals: cleanupFailure.fixture.store,
            fileSystem: cleanupFailure.fixture.fileSystem
        )

        await XCTAssertThrowsErrorAsync {
            try await cleanupRecovery.finalizeCommittedExtraction(
                operationID: cleanupFailure.fixture.header.operationID
            )
        }

        XCTAssertEqual(try Data(contentsOf: cleanupIndexURL), cleanupIndexBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanupFailure.rootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cleanupFailure.rootURL
                .appendingPathComponent("staging", isDirectory: true)
                .appendingPathComponent("unexpected")
                .path
        ))
        let reopenedDestination = try cleanupFailure.fixture.fileSystem
            .openDirectoryNoFollow(at: cleanupFailure.fixture.destinationURL)
        XCTAssertEqual(
            try cleanupFailure.fixture.fileSystem.identity(of: reopenedDestination),
            destinationIdentity
        )
        reopenedDestination.close()
        try await assertResolution(
            cleanupFailure.fixture.store,
            cleanupFailure.fixture.header.operationID,
            .committed
        )

        let releaseFailure = try await makeCommittedEmptyFixture()
        let releaseIndexURL = releaseFailure.fixture.namespace.url
            .appendingPathComponent("extraction-index.json")
        let releaseIndexBefore = try Data(contentsOf: releaseIndexURL)
        let releaseFileSystem = JournalTestFileSystem(
            base: releaseFailure.fixture.fileSystem
        )
        let releaseStore = TransactionJournalStore(
            indexDirectory: releaseFailure.fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: releaseFileSystem
        )
        let releaseRecovery = ExtractionRecoveryCoordinator(
            journals: releaseStore,
            fileSystem: releaseFileSystem
        )
        releaseFileSystem.failNextReplacementBeforeMutation()

        await XCTAssertThrowsErrorAsync {
            try await releaseRecovery.finalizeCommittedExtraction(
                operationID: releaseFailure.fixture.header.operationID
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: releaseFailure.rootURL.path))
        XCTAssertEqual(try Data(contentsOf: releaseIndexURL), releaseIndexBefore)
        try await assertResolution(
            releaseStore,
            releaseFailure.fixture.header.operationID,
            .committed
        )

        let postReplacementFailure = try await makeCommittedEmptyFixture()
        let postReplacementIndexURL = postReplacementFailure.fixture.namespace.url
            .appendingPathComponent("extraction-index.json")
        let postReplacementIndexBefore = try Data(contentsOf: postReplacementIndexURL)
        let postReplacementFileSystem = JournalTestFileSystem(
            base: postReplacementFailure.fixture.fileSystem
        )
        let postReplacementStore = TransactionJournalStore(
            indexDirectory: postReplacementFailure.fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: postReplacementFileSystem
        )
        let postReplacementRecovery = ExtractionRecoveryCoordinator(
            journals: postReplacementStore,
            fileSystem: postReplacementFileSystem
        )
        postReplacementFileSystem.failNextPostReplacementDirectoryFsync()

        await XCTAssertThrowsErrorAsync {
            try await postReplacementRecovery.finalizeCommittedExtraction(
                operationID: postReplacementFailure.fixture.header.operationID
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: postReplacementFailure.rootURL.path
        ))
        XCTAssertEqual(
            try Data(contentsOf: postReplacementIndexURL),
            postReplacementIndexBefore
        )
        let freshStore = TransactionJournalStore(
            indexDirectory: postReplacementFailure.fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: postReplacementFileSystem
        )
        try await assertResolution(
            freshStore,
            postReplacementFailure.fixture.header.operationID,
            .committed
        )
    }

    private func assertResolution(
        _ store: TransactionJournalStore,
        _ operationID: OperationID,
        _ expected: DurableOperationEffectResolution,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let actual = try await store.resolution(for: operationID)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private struct OpenHandles {
        let root: DirectoryHandle
        let staging: DirectoryHandle
        let destination: DirectoryHandle

        func close() {
            staging.close()
            destination.close()
            root.close()
        }
    }

    private struct CommittedFixture {
        let fixture: Task5TestSupport.Fixture
        let locator: TransactionRootLocator
        let rootURL: URL
        let destinationFile: URL
    }

    private func openHandles(
        _ fixture: Task5TestSupport.Fixture,
        locator: TransactionRootLocator
    ) throws -> OpenHandles {
        let root = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: Task5TestSupport.rootURL(fixture, locator: locator),
            expected: locator.rootIdentity
        )
        let staging = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: root,
            name: "staging",
            expected: nil
        )
        let destination = try fixture.fileSystem.openDirectoryNoFollow(at: fixture.destinationURL)
        return OpenHandles(root: root, staging: staging, destination: destination)
    }

    private func createFile(
        parent: DirectoryHandle,
        name: String,
        fileSystem: DarwinFileSystemOperations
    ) throws -> FileNodeIdentity {
        let file = try fileSystem.createRegularFileExclusive(parent: parent, name: name)
        try file.write(Data(name.utf8))
        try file.fsync()
        file.close()
        return try XCTUnwrap(fileSystem.statNoFollow(parent: parent, name: name)).identity
    }

    private func createExternalFile(
        at url: URL,
        parent: DirectoryHandle,
        fileSystem: DarwinFileSystemOperations
    ) throws -> FileNodeIdentity {
        try Data(url.lastPathComponent.utf8).write(to: url, options: .withoutOverwriting)
        return try XCTUnwrap(
            fileSystem.statNoFollow(parent: parent, name: url.lastPathComponent)
        ).identity
    }

    private func reference(
        _ root: TransactionRootKind,
        _ parent: DirectoryHandle,
        _ name: String,
        _ fileSystem: DarwinFileSystemOperations
    ) throws -> JournalNodeReference {
        try Task5TestSupport.nodeReference(
            root: root,
            parent: parent,
            name: name,
            fileSystem: fileSystem
        )
    }

    private func recover(_ fixture: Task5TestSupport.Fixture) async throws {
        let recovery = ExtractionRecoveryCoordinator(
            journals: fixture.store,
            fileSystem: fixture.fileSystem
        )
        try await recovery.recoverLiveTransactions()
    }

    private func makeCommittedEmptyFixture(
        manifest: StagingCleanupManifest = .init(entries: [])
    ) async throws -> CommittedFixture {
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let locator = try await Task5TestSupport.activate(fixture)
        try await fixture.store.markCommitted(
            transactionID: fixture.header.transactionID,
            result: Task5TestSupport.result(fixture)
        )
        return CommittedFixture(
            fixture: fixture,
            locator: locator,
            rootURL: Task5TestSupport.rootURL(fixture, locator: locator),
            destinationFile: fixture.destinationURL.appendingPathComponent("published")
        )
    }

    private func removeJournal(_ fixture: CommittedFixture) throws {
        let root = try fixture.fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: fixture.rootURL,
            expected: fixture.locator.rootIdentity
        )
        defer { root.close() }
        let journal = try XCTUnwrap(
            fixture.fixture.fileSystem.statNoFollow(parent: root, name: "journal")
        )
        try fixture.fixture.fileSystem.removeOwnedNoFollow(
            parent: root,
            name: "journal",
            expected: journal.identity
        )
    }

    func testSwapCrashMatrixRecoversIdempotently() async throws {
        for boundary in SwapCrashBoundary.allCases.filter({ !$0.isCommittedBoundary }) {
            let state = SwapCrashState()
            await XCTAssertThrowsErrorAsync {
                try await self.runSwapTransaction(until: boundary, state: state)
            }
            XCTAssertNil(state.retiredStore, "live journal store retained at \(boundary)")
            if boundary == .afterAppliedBeforeCommit {
                XCTAssertNotNil(state.appliedMutation)
                XCTAssertTrue(state.didValidateAppliedMutation)
            }
            try await assertSwapCrashState(
                state,
                boundary: boundary,
                expectedResolutionBeforeRecovery: .unfinished,
                expectedDestinationIdentityAfterRecovery: state.originalIdentity,
                expectedDestinationBytesAfterRecovery: Data("item".utf8),
                expectedResolutionAfterRecovery: .absent
            )
        }
    }

    func testCommittedCleanupCrashMatrixNeverTouchesPublicDestination() async throws {
        for boundary in SwapCrashBoundary.allCases.filter(\.isCommittedBoundary) {
            let state = SwapCrashState()
            await XCTAssertThrowsErrorAsync {
                try await self.runSwapTransaction(until: boundary, state: state)
            }
            XCTAssertNil(state.retiredStore, "live journal store retained at \(boundary)")
            let namespaceLocator = try XCTUnwrap(state.namespace)
            let header = try XCTUnwrap(state.header)
            let destinationURL = try XCTUnwrap(state.destinationURL)
            let rootURL = try XCTUnwrap(state.rootURL)
            let itemURL = try XCTUnwrap(state.itemURL)
            let detachedReplacementURL = try XCTUnwrap(state.detachedReplacementURL)
            let foreignIdentity = try XCTUnwrap(state.foreignPublicIdentity)

            XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))
            let before = try freshSwapRuntime(state)
            try await assertResolution(before.store, header.operationID, .committed)
            let namespace = try before.fileSystem.openTransactionOwnedDirectoryNoFollow(
                at: namespaceLocator.url,
                expected: namespaceLocator.identity
            )
            let rootIdentity = try XCTUnwrap(
                try before.fileSystem.statNoFollow(
                    parent: namespace,
                    name: rootURL.lastPathComponent
                )?.identity
            )
            namespace.close()
            let root = try before.fileSystem.openTransactionOwnedDirectoryNoFollow(
                at: rootURL,
                expected: rootIdentity
            )
            XCTAssertNotNil(try before.fileSystem.statNoFollow(parent: root, name: "journal"))
            let staging = try before.fileSystem.openTransactionOwnedDirectoryNoFollow(
                parent: root,
                name: "staging",
                expected: nil
            )
            let expectedPrivateInventory: [String: FileNodeIdentity] = boundary
                == .duringCommittedCleanup
                ? [:]
                : ["item": try XCTUnwrap(state.originalIdentity)]
            XCTAssertEqual(
                try directInventory(staging, fileSystem: before.fileSystem),
                expectedPrivateInventory,
                "committed private inventory before recovery at \(boundary)"
            )
            staging.close()
            root.close()
            let destination = try before.fileSystem.openDirectoryNoFollow(at: destinationURL)
            XCTAssertEqual(
                try before.fileSystem.statNoFollow(parent: destination, name: "item")?.identity,
                foreignIdentity
            )
            destination.close()
            XCTAssertEqual(try Data(contentsOf: itemURL), Data("foreign-public".utf8))
            XCTAssertEqual(try Data(contentsOf: detachedReplacementURL), Data("item".utf8))

            let firstRecorder = RecordingRecoveryObserver()
            let first = try freshSwapRuntime(state)
            try await ExtractionRecoveryCoordinator(
                journals: first.store,
                fileSystem: first.fileSystem,
                observer: firstRecorder
            ).recoverLiveTransactions()
            XCTAssertEqual(
                firstRecorder.boundaries.filter { $0 == .afterRolledBackPhasePersisted }.count,
                0,
                "committed mark count at \(boundary)"
            )
            XCTAssertEqual(
                firstRecorder.boundaries.filter { $0 == .afterRecoveryEntryReleased }.count,
                0,
                "committed release count at \(boundary)"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
            let firstDestination = try first.fileSystem.openDirectoryNoFollow(at: destinationURL)
            XCTAssertEqual(
                try first.fileSystem.statNoFollow(
                    parent: firstDestination,
                    name: "item"
                )?.identity,
                foreignIdentity
            )
            firstDestination.close()
            XCTAssertEqual(try Data(contentsOf: itemURL), Data("foreign-public".utf8))
            XCTAssertEqual(try Data(contentsOf: detachedReplacementURL), Data("item".utf8))
            try await assertResolution(first.store, header.operationID, .committed)

            let secondRecorder = RecordingRecoveryObserver()
            let second = try freshSwapRuntime(state)
            try await ExtractionRecoveryCoordinator(
                journals: second.store,
                fileSystem: second.fileSystem,
                observer: secondRecorder
            ).recoverLiveTransactions()
            XCTAssertEqual(
                secondRecorder.boundaries.filter { $0 == .afterRolledBackPhasePersisted }.count,
                0,
                "second committed mark count at \(boundary)"
            )
            XCTAssertEqual(
                secondRecorder.boundaries.filter { $0 == .afterRecoveryEntryReleased }.count,
                0,
                "second committed release count at \(boundary)"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
            let secondDestination = try second.fileSystem.openDirectoryNoFollow(at: destinationURL)
            XCTAssertEqual(
                try second.fileSystem.statNoFollow(
                    parent: secondDestination,
                    name: "item"
                )?.identity,
                foreignIdentity
            )
            secondDestination.close()
            XCTAssertEqual(try Data(contentsOf: itemURL), Data("foreign-public".utf8))
            XCTAssertEqual(try Data(contentsOf: detachedReplacementURL), Data("item".utf8))
            try await assertResolution(second.store, header.operationID, .committed)
        }
    }

    func testForeignCaptureCrashMatrixNeverTraversesOrDeletesForeignSubtree() async throws {
        for boundary in [
            ExtractionRecoveryBoundary.afterInverseRename,
            .afterInverseSourceParentSync,
            .afterInverseDestinationParentSync,
        ] {
            let manifest = StagingCleanupManifest(entries: [
                .init(relativePath: "item", kind: .regularFile),
            ])
            let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
            let locator = try await Task5TestSupport.activate(fixture)
            let handles = try openHandles(fixture, locator: locator)
            defer { handles.close() }
            let replacement = try createFile(
                parent: handles.staging,
                name: "item",
                fileSystem: fixture.fileSystem
            )
            let itemURL = fixture.destinationURL.appendingPathComponent("item")
            let detachedOriginalURL = fixture.destinationURL.appendingPathComponent(
                "original-detached"
            )
            _ = try createExternalFile(
                at: itemURL,
                parent: handles.destination,
                fileSystem: fixture.fileSystem
            )
            let originalNode = try XCTUnwrap(
                fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")
            )
            let captured = try CapturedTreeManifest.capture(
                rootPath: "item",
                rootNode: originalNode,
                parent: handles.destination,
                fileSystem: fixture.fileSystem,
                listingPolicy: Task5TestSupport.policy(
                    maximumJournalBytes: 1_048_576
                ).listing
            )
            try await fixture.store.armReplaceSwap(
                mutationID: JournalMutationID(rawValue: UUID()),
                staged: try reference(
                    .staging,
                    handles.staging,
                    "item",
                    fixture.fileSystem
                ),
                destination: try reference(
                    .destination,
                    handles.destination,
                    "item",
                    fixture.fileSystem
                ),
                replacementIdentity: replacement,
                expectedCaptured: captured,
                transactionID: fixture.header.transactionID
            )
            try FileManager.default.moveItem(at: itemURL, to: detachedOriginalURL)
            let foreignTarget = fixture.destinationURL.appendingPathComponent(
                "foreign-target",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: foreignTarget,
                withIntermediateDirectories: false
            )
            let sentinel = foreignTarget.appendingPathComponent("sentinel")
            try Data("foreign-bytes".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(
                at: itemURL,
                withDestinationURL: foreignTarget
            )
            let foreignIdentity = try XCTUnwrap(
                fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")?.identity
            )
            _ = try fixture.fileSystem.swapObserved(
                leftParent: handles.staging,
                leftName: "item",
                expectedLeft: replacement,
                rightParent: handles.destination,
                rightName: "item",
                expectedRight: foreignIdentity
            )

            let first = try freshStore(fixture)
            await XCTAssertThrowsErrorAsync {
                try await ExtractionRecoveryCoordinator(
                    journals: first,
                    fileSystem: fixture.fileSystem,
                    observer: ThrowOnceRecoveryObserver(boundary)
                ).recoverLiveTransactions()
            }
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("foreign-bytes".utf8))
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: itemURL.path),
                foreignTarget.path
            )

            let resumed = try freshStore(fixture)
            try await ExtractionRecoveryCoordinator(
                journals: resumed,
                fileSystem: fixture.fileSystem
            ).recoverLiveTransactions()
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("foreign-bytes".utf8))
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: itemURL.path),
                foreignTarget.path
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: detachedOriginalURL.path))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: Task5TestSupport.rootURL(fixture, locator: locator).path
            ))
            try await assertResolution(resumed, fixture.header.operationID, .absent)

            let second = try freshStore(fixture)
            try await ExtractionRecoveryCoordinator(
                journals: second,
                fileSystem: fixture.fileSystem
            ).recoverLiveTransactions()
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("foreign-bytes".utf8))
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: itemURL.path),
                foreignTarget.path
            )
            try await assertResolution(second, fixture.header.operationID, .absent)
        }
    }

    func testCommittedCleanupDeletesOnlyExactCapturedManifest() async throws {
        let state = SwapCrashState()
        await XCTAssertThrowsErrorAsync {
            try await self.runSwapTransaction(
                until: .afterCommitBeforeCleanup,
                state: state
            )
        }
        XCTAssertNil(state.retiredStore)
        let namespace = try XCTUnwrap(state.namespace)
        let header = try XCTUnwrap(state.header)
        let rootURL = try XCTUnwrap(state.rootURL)
        let itemURL = try XCTUnwrap(state.itemURL)
        let detachedReplacementURL = try XCTUnwrap(state.detachedReplacementURL)
        let outsideSentinel = namespace.url.appendingPathComponent("outside-sentinel")
        try Data("outside".utf8).write(to: outsideSentinel)

        let first = try freshSwapRuntime(state)
        try await ExtractionRecoveryCoordinator(
            journals: first.store,
            fileSystem: first.fileSystem
        ).recoverLiveTransactions()

        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
        XCTAssertEqual(try Data(contentsOf: outsideSentinel), Data("outside".utf8))
        XCTAssertEqual(try Data(contentsOf: itemURL), Data("foreign-public".utf8))
        XCTAssertEqual(try Data(contentsOf: detachedReplacementURL), Data("item".utf8))
        try await assertResolution(first.store, header.operationID, .committed)
    }

    func testCommittedCleanupUnexpectedPrivateNodePreservesRecoveryEvidence() async throws {
        let state = SwapCrashState()
        await XCTAssertThrowsErrorAsync {
            try await self.runSwapTransaction(
                until: .afterCommitBeforeCleanup,
                state: state
            )
        }
        XCTAssertNil(state.retiredStore)
        let namespaceLocator = try XCTUnwrap(state.namespace)
        let header = try XCTUnwrap(state.header)
        let rootURL = try XCTUnwrap(state.rootURL)
        let itemURL = try XCTUnwrap(state.itemURL)
        let detachedReplacementURL = try XCTUnwrap(state.detachedReplacementURL)
        let inspection = try freshSwapRuntime(state)
        let namespace = try inspection.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: namespaceLocator.url,
            expected: namespaceLocator.identity
        )
        let rootIdentity = try XCTUnwrap(
            try inspection.fileSystem.statNoFollow(
                parent: namespace,
                name: rootURL.lastPathComponent
            )?.identity
        )
        namespace.close()
        let root = try inspection.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: rootURL,
            expected: rootIdentity
        )
        let staging = try inspection.fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: root,
            name: "staging",
            expected: nil
        )
        _ = try createFile(
            parent: staging,
            name: "unexpected",
            fileSystem: inspection.fileSystem
        )
        try inspection.fileSystem.fsync(staging)
        try inspection.fileSystem.fsync(root)
        staging.close()
        root.close()

        for attempt in 1...2 {
            let fresh = try freshSwapRuntime(state)
            await XCTAssertThrowsErrorAsync {
                try await ExtractionRecoveryCoordinator(
                    journals: fresh.store,
                    fileSystem: fresh.fileSystem
                ).recoverLiveTransactions()
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent("journal").path
            ))
            XCTAssertEqual(
                try Data(contentsOf: rootURL.appendingPathComponent("staging/item")),
                Data("item".utf8),
                "captured node at attempt \(attempt)"
            )
            XCTAssertEqual(
                try Data(contentsOf: rootURL.appendingPathComponent("staging/unexpected")),
                Data("unexpected".utf8),
                "unexpected node at attempt \(attempt)"
            )
            XCTAssertEqual(try Data(contentsOf: itemURL), Data("foreign-public".utf8))
            XCTAssertEqual(try Data(contentsOf: detachedReplacementURL), Data("item".utf8))
            try await assertResolution(fresh.store, header.operationID, .committed)
        }
    }

    func testDirectoryCapturedManifestCrashMatrixRestoresOrRetainsWholeSubtree() async throws {
        for disposition in DirectoryCapturedCrashDisposition.allCases {
            let manifest = StagingCleanupManifest(entries: [
                .init(relativePath: "item", kind: .directory),
                .init(relativePath: "item/new.txt", kind: .regularFile),
            ])
            let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
            let locator = try await Task5TestSupport.activate(fixture)
            let handles = try openHandles(fixture, locator: locator)
            defer { handles.close() }

            let stagedDirectoryIdentity = try fixture.fileSystem.createDirectoryExclusive(
                parent: handles.staging,
                name: "item"
            )
            let stagedDirectory = try fixture.fileSystem.openDirectoryNoFollow(
                parent: handles.staging,
                name: "item",
                expected: stagedDirectoryIdentity
            )
            _ = try createFile(
                parent: stagedDirectory,
                name: "new.txt",
                fileSystem: fixture.fileSystem
            )
            stagedDirectory.close()

            let itemURL = fixture.destinationURL.appendingPathComponent(
                "item",
                isDirectory: true
            )
            let nestedURL = itemURL.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(
                at: nestedURL,
                withIntermediateDirectories: true
            )
            let oldFileURL = nestedURL.appendingPathComponent("old.txt")
            try Data("old-subtree".utf8).write(to: oldFileURL)
            let linkURL = itemURL.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(
                at: linkURL,
                withDestinationURL: oldFileURL
            )
            let originalNode = try XCTUnwrap(
                fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")
            )
            let captured = try CapturedTreeManifest.capture(
                rootPath: "item",
                rootNode: originalNode,
                parent: handles.destination,
                fileSystem: fixture.fileSystem,
                listingPolicy: Task5TestSupport.policy(
                    maximumJournalBytes: 1_048_576
                ).listing
            )
            try await fixture.store.armReplaceSwap(
                mutationID: JournalMutationID(rawValue: UUID()),
                staged: try reference(
                    .staging,
                    handles.staging,
                    "item",
                    fixture.fileSystem
                ),
                destination: try reference(
                    .destination,
                    handles.destination,
                    "item",
                    fixture.fileSystem
                ),
                replacementIdentity: stagedDirectoryIdentity,
                expectedCaptured: captured,
                transactionID: fixture.header.transactionID
            )

            if disposition != .armedBeforeSwap {
                _ = try fixture.fileSystem.swapObserved(
                    leftParent: handles.staging,
                    leftName: "item",
                    expectedLeft: stagedDirectoryIdentity,
                    rightParent: handles.destination,
                    rightName: "item",
                    expectedRight: originalNode.identity
                )
            }
            if disposition == .ambiguousAfterSwap {
                let detachedReplacement = fixture.destinationURL.appendingPathComponent(
                    "replacement-detached",
                    isDirectory: true
                )
                try FileManager.default.moveItem(at: itemURL, to: detachedReplacement)
                try FileManager.default.createDirectory(
                    at: itemURL,
                    withIntermediateDirectories: false
                )
                try Data("foreign".utf8).write(
                    to: itemURL.appendingPathComponent("foreign.txt")
                )

                let first = try freshStore(fixture)
                await XCTAssertThrowsErrorAsync {
                    try await ExtractionRecoveryCoordinator(
                        journals: first,
                        fileSystem: fixture.fileSystem
                    ).recoverLiveTransactions()
                }
                XCTAssertEqual(
                    try Data(contentsOf: itemURL.appendingPathComponent("foreign.txt")),
                    Data("foreign".utf8)
                )
                XCTAssertEqual(
                    try Data(contentsOf: Task5TestSupport.rootURL(
                        fixture,
                        locator: locator
                    ).appendingPathComponent("staging/item/nested/old.txt")),
                    Data("old-subtree".utf8)
                )
                XCTAssertEqual(
                    try Data(contentsOf: detachedReplacement.appendingPathComponent("new.txt")),
                    Data("new.txt".utf8)
                )
                XCTAssertTrue(FileManager.default.fileExists(
                    atPath: Task5TestSupport.rootURL(fixture, locator: locator).path
                ))
                try await assertResolution(first, fixture.header.operationID, .unfinished)

                let second = try freshStore(fixture)
                await XCTAssertThrowsErrorAsync {
                    try await ExtractionRecoveryCoordinator(
                        journals: second,
                        fileSystem: fixture.fileSystem
                    ).recoverLiveTransactions()
                }
                XCTAssertEqual(
                    try Data(contentsOf: Task5TestSupport.rootURL(
                        fixture,
                        locator: locator
                    ).appendingPathComponent("staging/item/nested/old.txt")),
                    Data("old-subtree".utf8)
                )
                XCTAssertEqual(
                    try Data(contentsOf: detachedReplacement.appendingPathComponent("new.txt")),
                    Data("new.txt".utf8)
                )
                try await assertResolution(second, fixture.header.operationID, .unfinished)
                continue
            }

            let first = try freshStore(fixture)
            try await ExtractionRecoveryCoordinator(
                journals: first,
                fileSystem: fixture.fileSystem
            ).recoverLiveTransactions()
            XCTAssertEqual(try Data(contentsOf: oldFileURL), Data("old-subtree".utf8))
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
                oldFileURL.path
            )
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: Task5TestSupport.rootURL(fixture, locator: locator).path
            ))
            try await assertResolution(first, fixture.header.operationID, .absent)

            let second = try freshStore(fixture)
            try await ExtractionRecoveryCoordinator(
                journals: second,
                fileSystem: fixture.fileSystem
            ).recoverLiveTransactions()
            XCTAssertEqual(try Data(contentsOf: oldFileURL), Data("old-subtree".utf8))
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
                oldFileURL.path
            )
            try await assertResolution(second, fixture.header.operationID, .absent)
        }
    }

    private func runSwapTransaction(
        until boundary: SwapCrashBoundary,
        state: SwapCrashState
    ) async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "item", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let locator = try await Task5TestSupport.activate(fixture)
        let handles = try openHandles(fixture, locator: locator)
        defer { handles.close() }
        let replacement = try createFile(
            parent: handles.staging,
            name: "item",
            fileSystem: fixture.fileSystem
        )
        let itemURL = fixture.destinationURL.appendingPathComponent("item")
        let original = try createExternalFile(
            at: itemURL,
            parent: handles.destination,
            fileSystem: fixture.fileSystem
        )
        let originalNode = try XCTUnwrap(
            fixture.fileSystem.statNoFollow(parent: handles.destination, name: "item")
        )
        let captured = try CapturedTreeManifest.capture(
            rootPath: "item",
            rootNode: originalNode,
            parent: handles.destination,
            fileSystem: fixture.fileSystem,
            listingPolicy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576).listing
        )
        let stagedReference = try reference(
            .staging,
            handles.staging,
            "item",
            fixture.fileSystem
        )
        let destinationReference = try reference(
            .destination,
            handles.destination,
            "item",
            fixture.fileSystem
        )
        let mutationID = JournalMutationID(rawValue: UUID())

        state.retiredStore = fixture.store
        state.namespace = fixture.namespace
        state.header = fixture.header
        state.destinationURL = fixture.destinationURL
        state.rootURL = Task5TestSupport.rootURL(fixture, locator: locator)
        state.itemURL = itemURL
        state.originalIdentity = original
        state.replacementIdentity = replacement
        state.expectedPrivateIdentityBeforeRecovery = replacement

        if boundary == .beforeManifestWrite {
            throw InjectedSwapCrash(boundary: boundary)
        }
        if boundary == .betweenManifestChunks {
            var entries = [CapturedTreeManifestEntry(
                relativePath: "",
                identity: original,
                byteCount: 0,
                allocatedByteCount: 0,
                timestamps: nil
            )]
            for index in 0..<900 {
                entries.append(CapturedTreeManifestEntry(
                    relativePath: String(format: "child-%05d", index),
                    identity: FileNodeIdentity(
                        device: original.device,
                        inode: UInt64(2_000_000 + index),
                        generation: 1,
                        kind: .regularFile
                    ),
                    byteCount: UInt64(index),
                    allocatedByteCount: UInt64(index),
                    timestamps: nil
                ))
            }
            let multiChunk = try CapturedTreeManifest(rootPath: "item", entries: entries)
            let crashingStore = TransactionJournalStore(
                indexDirectory: fixture.indexDirectory,
                indexFileName: "extraction-index.json",
                policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
                fileSystem: fixture.fileSystem,
                mutationObserver: ThrowOnFirstManifestChunkObserver(),
                manifestPreparationObserver: nil
            )
            do {
                try await crashingStore.armReplaceSwap(
                    mutationID: mutationID,
                    staged: stagedReference,
                    destination: destinationReference,
                    replacementIdentity: replacement,
                    expectedCaptured: multiChunk,
                    transactionID: fixture.header.transactionID
                )
                XCTFail("Expected manifest chunk crash")
            } catch {
                throw InjectedSwapCrash(boundary: boundary)
            }
        }

        try await fixture.store.armReplaceSwap(
            mutationID: mutationID,
            staged: stagedReference,
            destination: destinationReference,
            replacementIdentity: replacement,
            expectedCaptured: captured,
            transactionID: fixture.header.transactionID
        )
        if boundary == .afterArmedBeforeSwap {
            throw InjectedSwapCrash(boundary: boundary)
        }

        if boundary == .afterSwapBeforeObservation {
            let crashingFileSystem = DarwinFileSystemOperations(
                exclusiveRename: { renameatx_np($0, $1, $2, $3, UInt32(RENAME_EXCL)) },
                exchangeRename: { leftFD, leftName, rightFD, rightName in
                    let result = renameatx_np(
                        leftFD,
                        leftName,
                        rightFD,
                        rightName,
                        UInt32(RENAME_SWAP)
                    )
                    guard result == 0 else { return result }
                    errno = EIO
                    return -1
                }
            )
            do {
                _ = try crashingFileSystem.swapObserved(
                    leftParent: handles.staging,
                    leftName: "item",
                    expectedLeft: replacement,
                    rightParent: handles.destination,
                    rightName: "item",
                    expectedRight: original
                )
                XCTFail("Expected post-swap observation crash")
            } catch {
                state.expectedPrivateIdentityBeforeRecovery = original
                throw InjectedSwapCrash(boundary: boundary)
            }
        }

        _ = try fixture.fileSystem.swapObserved(
            leftParent: handles.staging,
            leftName: "item",
            expectedLeft: replacement,
            rightParent: handles.destination,
            rightName: "item",
            expectedRight: original
        )
        state.expectedPrivateIdentityBeforeRecovery = original
        if boundary == .afterObservationBeforeFirstParentSync {
            throw InjectedSwapCrash(boundary: boundary)
        }
        try fixture.fileSystem.fsync(handles.staging)
        if boundary == .betweenParentSyncs {
            throw InjectedSwapCrash(boundary: boundary)
        }
        try fixture.fileSystem.fsync(handles.destination)
        if boundary == .afterParentSyncBeforeAppliedRegistration {
            throw InjectedSwapCrash(boundary: boundary)
        }
        let appliedMutation = SwapCrashAppliedMutation(
            mutationID: mutationID,
            staged: stagedReference,
            destination: destinationReference,
            replacementIdentity: replacement,
            capturedManifest: captured
        )
        state.appliedMutation = appliedMutation
        let armedMutations = try await fixture.store.recordsForRecovery(
            fixture.header.transactionID
        )
        guard armedMutations == [
            .replaceSwap(
                mutationID: appliedMutation.mutationID,
                staged: appliedMutation.staged,
                destination: appliedMutation.destination,
                replacementIdentity: appliedMutation.replacementIdentity,
                expectedCaptured: appliedMutation.capturedManifest,
                recoveryCapturedIdentity: nil
            ),
        ] else {
            throw TransactionJournalError.unsafeRecoveryState(
                "armed replacement does not match applied crash state"
            )
        }
        state.didValidateAppliedMutation = true
        if boundary == .afterAppliedBeforeCommit {
            throw InjectedSwapCrash(boundary: boundary)
        }

        try await fixture.store.markCommitted(
            transactionID: fixture.header.transactionID,
            result: Task5TestSupport.result(fixture)
        )
        let detachedReplacementURL = fixture.destinationURL.appendingPathComponent(
            "replacement-detached"
        )
        try FileManager.default.moveItem(at: itemURL, to: detachedReplacementURL)
        try Data("foreign-public".utf8).write(to: itemURL)
        state.detachedReplacementURL = detachedReplacementURL
        state.foreignPublicIdentity = try fixture.fileSystem.statNoFollow(
            parent: handles.destination,
            name: "item"
        )?.identity
        if boundary == .afterCommitBeforeCleanup {
            throw InjectedSwapCrash(boundary: boundary)
        }

        let observer = ThrowOnceComponentObserver(
            boundary: .afterOwnedDirectRemoval,
            matches: { $0 == "item" }
        )
        let crashingFileSystem = DarwinFileSystemOperations(operationObserver: observer)
        let crashingStore = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: crashingFileSystem
        )
        do {
            try await ExtractionRecoveryCoordinator(
                journals: crashingStore,
                fileSystem: crashingFileSystem
            ).recoverLiveTransactions()
            XCTFail("Expected committed cleanup crash")
        } catch {
            throw InjectedSwapCrash(boundary: boundary)
        }
    }

    private func assertSwapCrashState(
        _ state: SwapCrashState,
        boundary: SwapCrashBoundary,
        expectedResolutionBeforeRecovery: DurableOperationEffectResolution,
        expectedDestinationIdentityAfterRecovery: FileNodeIdentity?,
        expectedDestinationBytesAfterRecovery: Data,
        expectedResolutionAfterRecovery: DurableOperationEffectResolution
    ) async throws {
        let namespaceLocator = try XCTUnwrap(state.namespace)
        let header = try XCTUnwrap(state.header)
        let destinationURL = try XCTUnwrap(state.destinationURL)
        let rootURL = try XCTUnwrap(state.rootURL)
        let itemURL = try XCTUnwrap(state.itemURL)
        let inspectionFileSystem = DarwinFileSystemOperations()
        let namespace = try inspectionFileSystem.openTransactionOwnedDirectoryNoFollow(
            at: namespaceLocator.url,
            expected: namespaceLocator.identity
        )
        let rootIdentity = try XCTUnwrap(
            try inspectionFileSystem.statNoFollow(
                parent: namespace,
                name: rootURL.lastPathComponent
            )?.identity
        )
        namespace.close()
        let root = try inspectionFileSystem.openTransactionOwnedDirectoryNoFollow(
            at: rootURL,
            expected: rootIdentity
        )
        XCTAssertNotNil(
            try inspectionFileSystem.statNoFollow(parent: root, name: "journal"),
            "journal before recovery at \(boundary)"
        )
        let staging = try inspectionFileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: root,
            name: "staging",
            expected: nil
        )
        XCTAssertEqual(
            try directInventory(staging, fileSystem: inspectionFileSystem),
            ["item": try XCTUnwrap(state.expectedPrivateIdentityBeforeRecovery)],
            "private inventory before recovery at \(boundary)"
        )
        staging.close()
        let before = try freshSwapRuntime(state)
        try await assertResolution(
            before.store,
            header.operationID,
            expectedResolutionBeforeRecovery
        )
        root.close()

        let firstRecorder = RecordingRecoveryObserver()
        let first = try freshSwapRuntime(state)
        try await ExtractionRecoveryCoordinator(
            journals: first.store,
            fileSystem: first.fileSystem,
            observer: firstRecorder
        ).recoverLiveTransactions()
        XCTAssertEqual(
            firstRecorder.boundaries.filter { $0 == .afterRolledBackPhasePersisted }.count,
            1,
            "rollback mark count at \(boundary)"
        )
        XCTAssertEqual(
            firstRecorder.boundaries.filter { $0 == .afterRecoveryEntryReleased }.count,
            1,
            "rollback release count at \(boundary)"
        )
        let destination = try first.fileSystem.openDirectoryNoFollow(at: destinationURL)
        let recoveredDestinationIdentity = try first.fileSystem.statNoFollow(
            parent: destination,
            name: "item"
        )?.identity
        destination.close()
        XCTAssertEqual(
            recoveredDestinationIdentity,
            expectedDestinationIdentityAfterRecovery,
            "destination identity after first recovery at \(boundary)"
        )
        let firstDestinationBytes = try Data(contentsOf: itemURL)
        XCTAssertEqual(firstDestinationBytes, expectedDestinationBytesAfterRecovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
        try await assertResolution(
            first.store,
            header.operationID,
            expectedResolutionAfterRecovery
        )

        let secondRecorder = RecordingRecoveryObserver()
        let second = try freshSwapRuntime(state)
        try await ExtractionRecoveryCoordinator(
            journals: second.store,
            fileSystem: second.fileSystem,
            observer: secondRecorder
        ).recoverLiveTransactions()
        XCTAssertEqual(
            secondRecorder.boundaries.filter { $0 == .afterRolledBackPhasePersisted }.count,
            0,
            "second rollback mark count at \(boundary)"
        )
        XCTAssertEqual(
            secondRecorder.boundaries.filter { $0 == .afterRecoveryEntryReleased }.count,
            0,
            "second rollback release count at \(boundary)"
        )
        let secondDestination = try second.fileSystem.openDirectoryNoFollow(at: destinationURL)
        let secondDestinationIdentity = try second.fileSystem.statNoFollow(
            parent: secondDestination,
            name: "item"
        )?.identity
        secondDestination.close()
        XCTAssertEqual(
            secondDestinationIdentity,
            recoveredDestinationIdentity,
            "destination identity changed during second recovery at \(boundary)"
        )
        XCTAssertEqual(try Data(contentsOf: itemURL), firstDestinationBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
        try await assertResolution(
            second.store,
            header.operationID,
            expectedResolutionAfterRecovery
        )
    }

    private func directInventory(
        _ directory: DirectoryHandle,
        fileSystem: any FileSystemOperations
    ) throws -> [String: FileNodeIdentity] {
        var inventory: [String: FileNodeIdentity] = [:]
        try fileSystem.forEachNodeNoFollow(directory) { node in
            inventory[node.name] = node.identity
        }
        return inventory
    }

    private func freshStore(
        _ fixture: Task5TestSupport.Fixture
    ) throws -> TransactionJournalStore {
        TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
    }

    private func freshSwapRuntime(_ state: SwapCrashState) throws -> FreshSwapRuntime {
        let namespace = try XCTUnwrap(state.namespace)
        let fileSystem = DarwinFileSystemOperations()
        let indexDirectory = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: namespace.url,
            expected: namespace.identity
        )
        let store = TransactionJournalStore(
            indexDirectory: indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fileSystem
        )
        return FreshSwapRuntime(fileSystem: fileSystem, store: store)
    }
}

private enum DirectoryCapturedCrashDisposition: CaseIterable {
    case armedBeforeSwap
    case afterSwap
    case ambiguousAfterSwap
}

private enum SwapCrashBoundary: CaseIterable, Sendable {
    case beforeManifestWrite
    case betweenManifestChunks
    case afterArmedBeforeSwap
    case afterSwapBeforeObservation
    case afterObservationBeforeFirstParentSync
    case betweenParentSyncs
    case afterParentSyncBeforeAppliedRegistration
    case afterAppliedBeforeCommit
    case afterCommitBeforeCleanup
    case duringCommittedCleanup

    var isCommittedBoundary: Bool {
        self == .afterCommitBeforeCleanup || self == .duringCommittedCleanup
    }
}

private struct InjectedSwapCrash: Error {
    let boundary: SwapCrashBoundary
}

private struct SwapCrashAppliedMutation: Equatable {
    let mutationID: JournalMutationID
    let staged: JournalNodeReference
    let destination: JournalNodeReference
    let replacementIdentity: FileNodeIdentity
    let capturedManifest: CapturedTreeManifest
}

private struct FreshSwapRuntime {
    let fileSystem: DarwinFileSystemOperations
    let store: TransactionJournalStore
}

private final class SwapCrashState {
    weak var retiredStore: TransactionJournalStore?
    var namespace: TransactionNamespaceLocator?
    var header: ExtractionJournalHeader?
    var destinationURL: URL?
    var rootURL: URL?
    var itemURL: URL?
    var detachedReplacementURL: URL?
    var originalIdentity: FileNodeIdentity?
    var replacementIdentity: FileNodeIdentity?
    var foreignPublicIdentity: FileNodeIdentity?
    var expectedPrivateIdentityBeforeRecovery: FileNodeIdentity?
    var appliedMutation: SwapCrashAppliedMutation?
    var didValidateAppliedMutation = false
}

private final class ThrowOnFirstManifestChunkObserver:
    JournalMutationObserving,
    @unchecked Sendable
{
    private var didThrow = false

    func didReach(_ event: JournalMutationEvent) throws {
        guard event == .preparationFrameWritten, !didThrow else { return }
        didThrow = true
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class RecoveryExclusiveRenameProbe: @unchecked Sendable {
    private let injectedName: String
    private let detachedName: String
    private let occupyAfterExchange: Bool
    private let lock = NSLock()
    private var calls = 0

    init(
        injectedName: String,
        detachedName: String,
        occupyAfterExchange: Bool
    ) {
        self.injectedName = injectedName
        self.detachedName = detachedName
        self.occupyAfterExchange = occupyAfterExchange
    }

    func call(
        fromFD: Int32,
        fromName: String,
        toFD: Int32,
        toName: String
    ) -> Int32 {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        guard call == 1, fromName == injectedName else {
            return renameatx_np(
                fromFD,
                fromName,
                toFD,
                toName,
                UInt32(RENAME_EXCL)
            )
        }
        guard renameat(fromFD, fromName, fromFD, detachedName) == 0,
              writeFile(parentFD: fromFD, name: fromName, contents: "foreign")
        else {
            errno = EIO
            return -1
        }
        let result = renameatx_np(
            fromFD,
            fromName,
            toFD,
            toName,
            UInt32(RENAME_EXCL)
        )
        guard result == 0 else { return result }
        if occupyAfterExchange,
           !writeFile(parentFD: fromFD, name: fromName, contents: "occupied") {
            errno = EIO
            return -1
        }
        return 0
    }

    private func writeFile(
        parentFD: Int32,
        name: String,
        contents: String
    ) -> Bool {
        let descriptor = openat(parentFD, name, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        let bytes = Array(contents.utf8)
        return write(descriptor, bytes, bytes.count) == bytes.count
    }
}

private final class ThrowOnceComponentObserver:
    FileSystemOperationObserving,
    @unchecked Sendable
{
    private let boundary: FileSystemOperationBoundary
    private let matches: (String) -> Bool
    private var didThrow = false

    init(
        boundary: FileSystemOperationBoundary,
        matches: @escaping (String) -> Bool
    ) {
        self.boundary = boundary
        self.matches = matches
    }

    func didReach(
        _ boundary: FileSystemOperationBoundary,
        component: String
    ) throws {
        guard boundary == self.boundary,
              matches(component),
              !didThrow
        else { return }
        didThrow = true
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class ThrowOnceJournalMutationObserver:
    JournalMutationObserving,
    @unchecked Sendable
{
    private let target: JournalMutationEvent
    private let lock = NSLock()
    private var didThrow = false

    init(_ target: JournalMutationEvent) {
        self.target = target
    }

    func didReach(_ event: JournalMutationEvent) throws {
        let shouldThrow = lock.withLock {
            guard event == target, !didThrow else { return false }
            didThrow = true
            return true
        }
        guard shouldThrow else { return }
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class RecordingJournalMutationObserver:
    JournalMutationObserving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedEvents: [JournalMutationEvent] = []

    var events: [JournalMutationEvent] {
        lock.withLock { recordedEvents }
    }

    func didReach(_ event: JournalMutationEvent) throws {
        lock.withLock { recordedEvents.append(event) }
    }
}

private final class TearRecoveryProgressFrameObserver:
    JournalMutationObserving,
    @unchecked Sendable
{
    private let journalURL: URL
    private let lock = NSLock()
    private var didTear = false

    init(journalURL: URL) {
        self.journalURL = journalURL
    }

    func didReach(_ event: JournalMutationEvent) throws {
        guard event == .recoveryProgressFrameWritten else { return }
        let shouldTear = lock.withLock {
            guard !didTear else { return false }
            didTear = true
            return true
        }
        guard shouldTear else { return }
        let handle = try FileHandle(forUpdating: journalURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard end > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try handle.truncate(atOffset: end - 1)
        try handle.synchronize()
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class ThrowOnceRecoveryObserver:
    ExtractionRecoveryObserving,
    @unchecked Sendable
{
    private let boundary: ExtractionRecoveryBoundary
    private var didThrow = false

    init(_ boundary: ExtractionRecoveryBoundary) {
        self.boundary = boundary
    }

    func didReach(_ boundary: ExtractionRecoveryBoundary) throws {
        guard boundary == self.boundary, !didThrow else { return }
        didThrow = true
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class RecordingRecoveryObserver:
    ExtractionRecoveryObserving,
    @unchecked Sendable
{
    private(set) var boundaries: [ExtractionRecoveryBoundary] = []

    func didReach(_ boundary: ExtractionRecoveryBoundary) throws {
        boundaries.append(boundary)
    }
}

private final class ThrowOnceObserver: FileSystemOperationObserving, @unchecked Sendable {
    private let target: FileSystemOperationBoundary
    private let lock = NSLock()
    private var didThrow = false

    init(_ target: FileSystemOperationBoundary) {
        self.target = target
    }

    func didReach(
        _ boundary: FileSystemOperationBoundary,
        component: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard boundary == target, !didThrow else { return }
        didThrow = true
        throw CocoaError(.fileWriteUnknown)
    }
}

private extension TransactionJournalStore {
    func resolutionValue(
        for operationID: OperationID
    ) async throws -> DurableOperationEffectResolution {
        try await resolution(for: operationID)
    }
}
