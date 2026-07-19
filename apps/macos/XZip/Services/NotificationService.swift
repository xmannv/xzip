import Foundation
import UserNotifications
import AppKit

/// Posts system notifications when queue operations finish (mockup 4d).
///
/// Design: a thin wrapper over `UNUserNotificationCenter`. `AppModel` calls
/// `notifyCompletion` when an operation completes; the "Reveal" action button is
/// handled by the app delegate-less `UNUserNotificationCenterDelegate` set here.
/// Gated by the `showNotifications` preference so users can silence it.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private let revealActionID = "xzip.reveal"
    private let categoryID = "xzip.completion"
    /// Maps a delivered notification to the file it should reveal.
    private var revealTargets: [String: URL] = [:]

    private override init() {
        super.init()
    }

    /// Request authorization + register the "Reveal" action. Safe to call at launch.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // No `.foreground`: the action only reveals the file in Finder, so it
        // must NOT bring XZip forward. `.foreground` asks LaunchServices to
        // activate the app by bundle id, which — when several copies of the app
        // are registered (dev builds, /Applications, etc.) — can launch a
        // *different* copy and surface a second instance. The delegate callback
        // still fires without it, so the Finder reveal works regardless.
        let reveal = UNNotificationAction(identifier: revealActionID, title: "Reveal", options: [])
        let category = UNNotificationCategory(
            identifier: categoryID, actions: [reveal], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post a completion notification unless the user disabled them.
    func notifyCompletion(title: String, body: String, revealURL: URL?) {
        guard UserDefaults.standard.object(forKey: XZIPDefaults.showNotifications) == nil
                || UserDefaults.standard.bool(forKey: XZIPDefaults.showNotifications) else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryID

        let id = UUID().uuidString
        if let revealURL {
            // Bound the map: there is no "notification dismissed" callback, so
            // without this an un-tapped notification's target would linger for the
            // whole session and the map would grow without limit.
            if revealTargets.count >= 64, let stale = revealTargets.keys.first {
                revealTargets.removeValue(forKey: stale)
            }
            revealTargets[id] = revealURL
        }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even while the app is frontmost.
    ///
    /// Uses the completion-handler variant and is `nonisolated` so it satisfies
    /// the protocol requirement without Swift 6 flagging the non-Sendable
    /// `UNUserNotificationCenter`/`UNNotification` params crossing into the
    /// `@MainActor` class. No actor state is touched here.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Handle the "Reveal" action (and default tap) by opening Finder. Hops to
    /// the main actor to read `revealTargets` and complete.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        // UN delegate callbacks are delivered on the main thread, so we can
        // safely assume main-actor isolation instead of hopping via a Task
        // (which would require sending the non-Sendable completion handler).
        MainActor.assumeIsolated {
            if let url = revealTargets[id] {
                revealTargets[id] = nil
                // Tapping a notification body makes macOS activate XZip — a
                // default behaviour that can't be disabled via the notification
                // API. Revealing immediately loses a focus race: our activation
                // finishes *after* the reveal, so XZip ends up frontmost and
                // hides Finder. Deferring the reveal a short beat lets our
                // activation settle first, so Finder is raised last and wins.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        completionHandler()
    }
}
