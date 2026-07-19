import Foundation

/// Resolves the "open at launch" preference (a stored Place UUID) against the
/// current Places list. Pure logic, kept out of `AppModel` so it can be unit
/// tested without constructing the model.
enum StartupLocation {
    /// nil = show the Start screen (unset, malformed, or unknown id — e.g.
    /// the chosen Place was removed since).
    static func resolve(storedID: String?, places: [Place]) -> Place? {
        guard let storedID, !storedID.isEmpty,
              let id = UUID(uuidString: storedID) else { return nil }
        return places.first { $0.id == id }
    }
}
