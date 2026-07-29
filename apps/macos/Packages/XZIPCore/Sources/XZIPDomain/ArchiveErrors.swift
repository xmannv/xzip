import Darwin
import Foundation

public enum ArchiveResourceLimitKind: String, Codable, Sendable {
    case listingEntries
    case pathBytes
    case advertisedOutputBytes
    case processStdoutBytes
    case processStderrBytes
    case cacheWeight
    case stagingBytes
    case commandBytes
    case journalBytes
    case temporaryArtifactRoots
}

/// Why a rollback could not finish, and what the caller was originally failing
/// at when it started.
///
/// Both halves matter. A bare "rollback failed" tells the user neither what went
/// wrong with their extraction nor why the cleanup could not undo it, and those
/// are usually different problems with different remedies — a full disk needs
/// space freed, a permission error needs the destination changed.
///
/// Descriptions are captured as strings rather than the errors themselves so
/// `ArchiveFailure` stays `Equatable`; `posixCode` is kept separately because
/// that is the part worth branching on.
public struct RollbackCause: Equatable, Sendable {
    /// The failure that triggered the rollback, when there was one. Absent for
    /// rollbacks starting from a state that was already inconsistent.
    public let originalDescription: String?
    /// The failure that stopped the rollback from completing.
    public let rollbackDescription: String
    /// `errno` behind `rollbackDescription`, when it came from a syscall.
    public let posixCode: Int32?

    public init(
        originalDescription: String?,
        rollbackDescription: String,
        posixCode: Int32?
    ) {
        self.originalDescription = originalDescription
        self.rollbackDescription = rollbackDescription
        self.posixCode = posixCode
    }

    /// Worth singling out because it is both the most likely cause of a
    /// mid-extraction rollback failure and the one the user can act on directly.
    public var isOutOfSpace: Bool { posixCode == ENOSPC }
}

public enum ArchiveFailure: Error, Equatable, Sendable {
    case resourceLimitExceeded(kind: ArchiveResourceLimitKind, limit: UInt64, observed: UInt64)
    case unsafePath(entry: String)
    case unsupportedEntryName(entry: String, reason: String)
    case unsupportedNode(entry: String, type: String)
    case filesystemNameCollision(entries: [String])
    case authenticationRequired(sessionID: ArchiveSessionID, operationID: OperationID)
    case stalePasswordRequest(operationID: OperationID)
    case archiveChanged
    case destinationConflict(path: String)
    case destructiveReplacementApprovalRequired
    case extractionPlanChanged
    case unresolvedConflictPolicy
    case untrustedCommand
    case replayedCommand
    case brokerUnavailable
    case unsupportedProtocolVersion
    /// Rollback could not restore the destination. `recoveryURL` is where the
    /// leftover transaction state sits; `cause` says what went wrong, and is
    /// `nil` only for call sites that have not been given one yet.
    case rollbackFailed(recoveryURL: URL, cause: RollbackCause?)
    case unsupportedFormat
}

/// Without this the app's `error.localizedDescription` renders these as
/// "The operation couldn't be completed. (XZIPDomain.ArchiveFailure error 13.)",
/// which is how every one of these reached the user. Sibling error types in this
/// module already conform; this one was missed.
extension ArchiveFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .resourceLimitExceeded(kind, limit, observed):
            return "The archive exceeds the \(kind.rawValue) limit "
                + "(\(observed) vs \(limit))."
        case let .unsafePath(entry):
            return "The archive contains an unsafe path: \(entry)"
        case let .unsupportedEntryName(entry, reason):
            return "The archive contains an unsupported name (\(reason)): \(entry)"
        case let .unsupportedNode(entry, type):
            return "The archive contains an unsupported \(type): \(entry)"
        case let .filesystemNameCollision(entries):
            return "These entries would collide on this filesystem: "
                + entries.joined(separator: ", ")
        case .authenticationRequired:
            return "This archive needs a password."
        case .stalePasswordRequest:
            return "That password request is no longer current. Try again."
        case .archiveChanged:
            return "The archive changed on disk. Reload it and try again."
        case let .destinationConflict(path):
            return "Something already exists at \(path)."
        case .destructiveReplacementApprovalRequired:
            return "Replacing these folders needs your confirmation."
        case .extractionPlanChanged:
            return "The archive or destination changed. Review the replacement again."
        case .unresolvedConflictPolicy:
            return "No decision was made about how to handle existing files."
        case .untrustedCommand:
            return "That command could not be verified."
        case .replayedCommand:
            return "That command was already carried out."
        case .brokerUnavailable:
            return "The helper service is not available."
        case .unsupportedProtocolVersion:
            return "The helper service speaks a different version."
        case let .rollbackFailed(recoveryURL, cause):
            return Self.rollbackMessage(recoveryURL: recoveryURL, cause: cause)
        case .unsupportedFormat:
            return "That archive format is not supported."
        }
    }

    /// Leads with what the user can act on. Out of space is called out by name
    /// because it is the common cause here and the remedy is obvious once said;
    /// anything else reports both failures, since the original error explains
    /// what they were trying to do and the rollback error explains why the
    /// leftovers are still there.
    private static func rollbackMessage(
        recoveryURL: URL,
        cause: RollbackCause?
    ) -> String {
        guard let cause else {
            return "The extraction could not be undone cleanly. "
                + "Partial files are at \(recoveryURL.path)."
        }
        var message: String
        if cause.isOutOfSpace {
            message = "The disk ran out of space, and the extraction could not "
                + "be undone cleanly."
        } else {
            message = "The extraction could not be undone cleanly "
                + "(\(cause.rollbackDescription))."
        }
        if let original = cause.originalDescription {
            message += " It was already failing: \(original)"
        }
        message += " Partial files are at \(recoveryURL.path)."
        return message
    }
}
