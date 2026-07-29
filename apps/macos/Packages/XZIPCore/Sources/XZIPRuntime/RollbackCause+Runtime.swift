import Darwin
import Foundation
import XZIPCore
import XZIPDomain

extension RollbackCause {
    /// Builds the cause reported with `ArchiveFailure.rollbackFailed`.
    ///
    /// Lives in XZIPRuntime because it bridges two modules that do not see each
    /// other: `RollbackCause` is in XZIPDomain, while `FileSystemOperationError`
    /// is in XZIPCore.
    ///
    /// - Parameters:
    ///   - original: the failure that started the rollback, if any.
    ///   - rollback: the failure that stopped it from completing.
    init(original: Error?, rollback: Error) {
        self.init(
            originalDescription: original.map(Self.describe),
            rollbackDescription: Self.describe(rollback),
            posixCode: Self.posixCode(of: rollback)
        )
    }

    /// Recovers the `errno` behind an error so callers can distinguish a full
    /// disk from a permission problem.
    ///
    /// Covers both shapes this codebase produces: `FileSystemOperationError`
    /// wraps syscall failures in `.posix`, while the raw paths throw `NSError` in
    /// `NSPOSIXErrorDomain`. Anything else has no errno to report.
    private static func posixCode(of error: Error) -> Int32? {
        if case let FileSystemOperationError.posix(_, code) = error {
            return code
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(nsError.code)
        }
        return nil
    }

    /// Prefers a `LocalizedError`'s own wording and falls back to the
    /// reflected case name, which stays readable for the enum errors here
    /// (`unsafeRecoveryState("staging inventory remains")`) unlike
    /// `localizedDescription`, which would render them as "error 3".
    private static func describe(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        if case let FileSystemOperationError.posix(function, code) = error {
            return "\(function) failed: \(Self.errnoText(code))"
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Self.errnoText(Int32(nsError.code))
        }
        return String(describing: error)
    }

    private static func errnoText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
