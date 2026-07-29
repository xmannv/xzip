import Foundation
import XZIPDomain

/// Carries a per-operation extraction credential across the one seam that
/// cannot pass it as an argument.
///
/// `TransactionalArchiveExtractionHandler` obtains the password from an
/// `EphemeralExtractionCredentialResolving` that is injected once, at assembly
/// time — long before any password exists. The password itself only appears
/// per-operation, from the UI. The security brief closes the obvious route:
/// neither `ExtractionRequest` nor `OperationDescriptor` may carry a credential,
/// so it cannot simply ride along with the request.
///
/// This registry bridges that gap. The caller deposits the password against the
/// `OperationID` it is about to extract under, and the resolver withdraws it.
///
/// **Withdrawal removes.** `resolveExtractionCredential` deletes the entry as it
/// returns it, so "at most once per operation" is a property of the structure
/// rather than something every caller has to remember. A second resolve for the
/// same operation yields `nil`, which the handler treats as passwordless.
///
/// Depositing is not enough on its own: an operation that dies between deposit
/// and withdrawal (unreadable archive, cancellation) would leave the secret
/// behind, so callers must `discard` on every exit path.
///
/// As the brief states for the whole credential path, this controls reference
/// lifetime; it is not a claim that Swift `String` storage is zeroized.
actor EphemeralCredentialRegistry: EphemeralExtractionCredentialResolving {

    private var credentials: [OperationID: String] = [:]

    /// Number of credentials currently held. Exists so tests can prove the
    /// registry is empty after an operation ends, however it ended.
    var count: Int { credentials.count }

    /// Stores `password` for the operation that is about to run.
    func deposit(_ password: String, for operationID: OperationID) {
        credentials[operationID] = password
    }

    /// Drops any credential still held for `operationID`.
    ///
    /// Safe to call when nothing was deposited or after a successful withdrawal,
    /// so callers can invoke it unconditionally from a `defer`.
    func discard(_ operationID: OperationID) {
        credentials[operationID] = nil
    }

    /// Returns and removes the credential deposited for this operation.
    ///
    /// The identifiers come from the validated descriptor; only `operationID`
    /// selects the credential, and no ambient or UI state is consulted.
    func resolveExtractionCredential(
        sessionID: ArchiveSessionID,
        operationID: OperationID,
        archiveID: ArchiveID
    ) async throws -> String? {
        credentials.removeValue(forKey: operationID)
    }
}
