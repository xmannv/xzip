import XZIPCore

struct ReplaceSwapOccupancy: Equatable, Sendable {
    let staged: FileNodeIdentity?
    let destination: FileNodeIdentity?
}

enum ActiveReplaceSwapAction: Equatable, Sendable {
    case noEffect
    case reverseSwap(capturedIdentity: FileNodeIdentity)
    case unresolved
}

enum CommittedReplaceCleanupAction: Equatable, Sendable {
    case cleanupCaptured
    case unresolved
}

enum SwapClaimRecoveryError: Error, Equatable, Sendable {
    case unsafeActiveOccupancy(
        staged: FileNodeIdentity?,
        destination: FileNodeIdentity?
    )
    case unsafeCommittedPrivateState(actual: FileNodeIdentity?)
    case capturedManifestMismatch
    case inverseObservationMismatch(
        staged: FileNodeIdentity?,
        destination: FileNodeIdentity?
    )
}

struct SwapClaimRecoveryClassifier: Sendable {
    func classifyActive(
        occupancy: ReplaceSwapOccupancy,
        replacementIdentity: FileNodeIdentity,
        expectedCapturedIdentity: FileNodeIdentity
    ) -> ActiveReplaceSwapAction {
        if occupancy.staged == replacementIdentity,
           occupancy.destination == expectedCapturedIdentity {
            return .noEffect
        }
        if occupancy.destination == replacementIdentity,
           let staged = occupancy.staged {
            return .reverseSwap(capturedIdentity: staged)
        }
        return .unresolved
    }

    func classifyCommitted(
        stagedIdentity: FileNodeIdentity?,
        expectedCapturedIdentity: FileNodeIdentity,
        capturedManifestMatches: Bool
    ) -> CommittedReplaceCleanupAction {
        guard stagedIdentity == expectedCapturedIdentity,
              capturedManifestMatches else {
            return .unresolved
        }
        return .cleanupCaptured
    }
}
