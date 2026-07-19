import Foundation
import Observation
import SwiftUI
import AppKit
import XZIPCore

extension AppModel {
    // MARK: - Password vault (Keychain)

    /// The stable, collision-free vault key for an archive: its full
    /// standardized path. Keying by `lastPathComponent` alone made two archives
    /// with the same filename in different folders share (and overwrite) one
    /// Keychain entry, so opening one could auto-fill the other's password.
    func vaultKey(for url: URL) -> String { url.standardizedFileURL.path }

    func vaultPassword(for key: String) -> String? {
        service.savedPassword(for: key)
    }

    /// Returns a saved vault password for the user to reuse, gated behind local
    /// authentication when the "Require authentication to reveal passwords"
    /// preference is on (its default). Returns nil if auth is required and the
    /// user cancels or fails it. Every UI path that surfaces a saved password to
    /// the user must go through this — the raw `vaultPassword(for:)` is only for
    /// silent auto-unlock, which never displays the value.
    func revealVaultPassword(for key: String) async -> String? {
        let requireAuth = UserDefaults.standard
            .object(forKey: XZIPDefaults.requireAuthToReveal) as? Bool ?? true
        if requireAuth {
            let reason = String(localized: "Authenticate to use a saved password")
            guard await AuthService.authenticate(reason: reason) else { return nil }
        }
        return service.savedPassword(for: key)
    }

    func saveVaultPassword(_ password: String, for key: String) {
        guard !key.isEmpty, !password.isEmpty else { return }
        do {
            try service.savePassword(password, for: key)
            reloadVault()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteVaultPassword(for key: String) {
        do {
            try service.deletePassword(for: key)
            reloadVault()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadVault() {
        vaultKeys = service.vaultKeys().sorted()
    }
}
