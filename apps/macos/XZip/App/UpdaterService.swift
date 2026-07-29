import Foundation
import Sparkle

/// Wraps Sparkle's updater so the rest of the app depends on a small, stable
/// surface instead of Sparkle types directly.
///
/// Design: the Facade pattern over `SPUStandardUpdaterController`, plus an
/// `ObservableObject` so SwiftUI can bind a "Check for Updates" menu item and
/// reflect whether checks are currently allowed. Keeps auto-update wiring in one
/// place and makes it easy to stub in previews.
@MainActor
final class UpdaterService: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Whether a manual update check can be triggered right now. Stays false
    /// (menu item disabled) when Sparkle isn't configured with a real feed/key.
    @Published var canCheckForUpdates = false

    /// Whether a real appcast feed + EdDSA public key are configured. When the
    /// Info.plist still holds the release-time placeholders, auto-update is off
    /// so the app doesn't nag with "Unable to Check For Updates" on launch.
    let isConfigured: Bool

    init() {
        isConfigured = Self.hasValidUpdateConfig()

        // Only start the scheduled updater when properly configured. Otherwise
        // we construct the controller without starting it, so no launch-time
        // check fires against a placeholder feed.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        guard isConfigured else {
            // Belt-and-suspenders: make sure no background checks are scheduled.
            controller.updater.automaticallyChecksForUpdates = false
            return
        }

        controller.startUpdater()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Trigger a user-initiated update check (e.g. from the app menu).
    func checkForUpdates() {
        guard isConfigured else { return }
        controller.updater.checkForUpdates()
    }

    /// True only when SUFeedURL is a real https URL and SUPublicEDKey has been
    /// replaced with an actual key (not the committed placeholder).
    private static func hasValidUpdateConfig() -> Bool {
        let info = Bundle.main.infoDictionary
        let feed = (info?["SUFeedURL"] as? String) ?? ""
        let key = (info?["SUPublicEDKey"] as? String) ?? ""
        let feedOK = feed.hasPrefix("https://") && !feed.isEmpty
        let keyOK = !key.isEmpty && !key.contains("REPLACE")
        return feedOK && keyOK
    }
}
