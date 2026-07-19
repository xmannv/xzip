import Foundation
import LocalAuthentication

/// Gates sensitive actions (revealing a saved password) behind local
/// authentication — Touch ID, Apple Watch, or the device password.
///
/// Design: a thin async wrapper over `LAContext`. Falls back through
/// `.deviceOwnerAuthentication` so a Mac without Touch ID still prompts for the
/// login password. If no authentication is available at all (unlikely on
/// macOS), it fails closed — the caller should treat that as "not authorized".
enum AuthService {
    /// Prompt the user to authenticate. Returns true only on success.
    /// - Parameter reason: user-facing explanation shown in the system dialog.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        // `.deviceOwnerAuthentication` = biometrics OR password, so this works
        // on Macs without Touch ID.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }

        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
