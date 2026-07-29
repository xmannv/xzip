import XCTest
@testable import XZIPCore
@testable import XZIPRuntime

final class SwapClaimRecoveryTests: XCTestCase {
    private let classifier = SwapClaimRecoveryClassifier()
    private let replacement = identity(inode: 1)
    private let existing = identity(inode: 2)
    private let foreign = identity(inode: 3)
    private let foreignPublic = identity(inode: 4)

    func testActivePreEffectStateNeedsNoSwap() {
        XCTAssertEqual(
            classifier.classifyActive(
                occupancy: .init(staged: replacement, destination: existing),
                replacementIdentity: replacement,
                expectedCapturedIdentity: existing
            ),
            .noEffect
        )
    }

    func testActiveCompletedExpectedSwapReversesExpectedCapture() {
        XCTAssertEqual(
            classifier.classifyActive(
                occupancy: .init(staged: existing, destination: replacement),
                replacementIdentity: replacement,
                expectedCapturedIdentity: existing
            ),
            .reverseSwap(capturedIdentity: existing)
        )
    }

    func testActiveForeignCaptureReversesForeignWhenDestinationIsReplacement() {
        XCTAssertEqual(
            classifier.classifyActive(
                occupancy: .init(staged: foreign, destination: replacement),
                replacementIdentity: replacement,
                expectedCapturedIdentity: existing
            ),
            .reverseSwap(capturedIdentity: foreign)
        )
    }

    func testActiveForeignAndForeignPublicStateIsUnresolved() {
        XCTAssertEqual(
            classifier.classifyActive(
                occupancy: .init(staged: foreign, destination: foreignPublic),
                replacementIdentity: replacement,
                expectedCapturedIdentity: existing
            ),
            .unresolved
        )
    }

    func testActiveReplacementStillStagedWithForeignPublicNodeIsUnresolved() {
        XCTAssertEqual(
            classifier.classifyActive(
                occupancy: .init(staged: replacement, destination: foreignPublic),
                replacementIdentity: replacement,
                expectedCapturedIdentity: existing
            ),
            .unresolved
        )
    }

    func testActiveMissingStagedStateIsUnresolved() {
        XCTAssertEqual(
            classifier.classifyActive(
                occupancy: .init(staged: nil, destination: replacement),
                replacementIdentity: replacement,
                expectedCapturedIdentity: existing
            ),
            .unresolved
        )
        XCTAssertEqual(
            classifier.classifyActive(
                occupancy: .init(staged: nil, destination: foreignPublic),
                replacementIdentity: replacement,
                expectedCapturedIdentity: existing
            ),
            .unresolved
        )
    }

    func testActiveMissingDestinationStateIsUnresolved() {
        XCTAssertEqual(
            classifier.classifyActive(
                occupancy: .init(staged: existing, destination: nil),
                replacementIdentity: replacement,
                expectedCapturedIdentity: existing
            ),
            .unresolved
        )
    }

    func testCommittedCleanupIgnoresLaterPublicDestinationChanges() {
        XCTAssertEqual(
            classifier.classifyCommitted(
                stagedIdentity: existing,
                expectedCapturedIdentity: existing,
                capturedManifestMatches: true
            ),
            .cleanupCaptured
        )
    }

    func testCommittedCleanupRequiresExpectedPrivateIdentityAndManifest() {
        XCTAssertEqual(
            classifier.classifyCommitted(
                stagedIdentity: foreign,
                expectedCapturedIdentity: existing,
                capturedManifestMatches: true
            ),
            .unresolved
        )
        XCTAssertEqual(
            classifier.classifyCommitted(
                stagedIdentity: existing,
                expectedCapturedIdentity: existing,
                capturedManifestMatches: false
            ),
            .unresolved
        )
        XCTAssertEqual(
            classifier.classifyCommitted(
                stagedIdentity: nil,
                expectedCapturedIdentity: existing,
                capturedManifestMatches: true
            ),
            .unresolved
        )
    }
}

private func identity(inode: UInt64) -> FileNodeIdentity {
    FileNodeIdentity(
        device: 1,
        inode: inode,
        generation: nil,
        kind: .regularFile
    )
}
