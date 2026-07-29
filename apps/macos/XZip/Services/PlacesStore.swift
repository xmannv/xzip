import Foundation
import os

/// Persists the user's favorite extraction destinations ("Places") as file
/// bookmarks in `UserDefaults`.
///
/// Design: the Repository pattern over `UserDefaults`. Each place is stored as a
/// bookmark blob so a renamed or moved folder still resolves. Kept separate from
/// `AppModel` so the persistence details never leak into the SwiftUI layer.
///
/// Bookmarks are deliberately **not** security-scoped: XZip ships unsandboxed
/// (see XZip.entitlements), where `.withSecurityScope` grants nothing and only
/// suggests to a reader that sandbox plumbing is in play. Plain bookmarks resolve
/// the same folders without that misdirection.
struct PlacesStore {
    private let defaultsKey = "xzip.places.v1"
    private let defaults: UserDefaults
    private static let log = Logger(subsystem: "com.codetay.xzip", category: "PlacesStore")

    /// Called when a place could not be persisted or resolved, so the UI can say
    /// so. Previously these failures were dropped by a `compactMap`, and a place
    /// would quietly vanish from the sidebar with nothing to explain why.
    var onFailure: (@Sendable (String) -> Void)?

    init(
        defaults: UserDefaults = .standard,
        onFailure: (@Sendable (String) -> Void)? = nil
    ) {
        self.defaults = defaults
        self.onFailure = onFailure
    }

    /// A persisted place: display metadata + the file bookmark.
    private struct StoredPlace: Codable {
        var id: UUID
        var name: String
        var symbol: String
        var bookmark: Data
    }

    // MARK: - Load

    /// Load saved places, resolving each bookmark to a current URL.
    /// Stale bookmarks are refreshed in place when possible.
    func load() -> [Place] {
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode([StoredPlace].self, from: data) else {
            return Self.systemDefaults()
        }
        var resolved: [Place] = []
        var kept: [StoredPlace] = []
        var changed = false
        var unresolved: [String] = []
        for entry in stored {
            var isStale = false
            let url: URL
            do {
                url = try URL(
                    resolvingBookmarkData: entry.bookmark,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                // Could not resolve THIS session (e.g. an unmounted external
                // volume). Keep the stored entry untouched so the place returns
                // when the volume is back — never silently drop it from storage.
                // The name is the only user data logged, and privately.
                Self.log.error(
                    "Place \(entry.name, privacy: .private) did not resolve: \(error.localizedDescription, privacy: .public)")
                unresolved.append(entry.name)
                kept.append(entry)
                continue
            }
            resolved.append(Place(id: entry.id, name: entry.name, url: url, symbol: entry.symbol))
            // A stale-but-resolvable bookmark must be refreshed, or it decays until
            // it stops resolving and the place is lost for good.
            if isStale, let fresh = try? url.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                var refreshed = entry
                refreshed.bookmark = fresh
                kept.append(refreshed)
                changed = true
            } else {
                kept.append(entry)
            }
        }
        if changed, let data = try? JSONEncoder().encode(kept) {
            defaults.set(data, forKey: defaultsKey)
        }
        if let first = unresolved.first {
            report(unresolved.count == 1
                ? String(localized: "The place “\(first)” is unavailable right now. It will come back when its volume is reachable.")
                : String(localized: "\(unresolved.count) places are unavailable right now. They will come back when their volumes are reachable."))
        }
        return resolved
    }

    // MARK: - Save

    /// Persist the given places, creating a bookmark for each.
    ///
    /// A folder that cannot be bookmarked is reported rather than dropped: the
    /// old `compactMap` removed it from storage, so the place disappeared from
    /// the sidebar on the next launch with no indication of what happened.
    func save(_ places: [Place]) {
        var stored: [StoredPlace] = []
        var failed: [String] = []
        for place in places {
            do {
                let bookmark = try place.url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                stored.append(StoredPlace(
                    id: place.id, name: place.name, symbol: place.symbol, bookmark: bookmark))
            } catch {
                Self.log.error(
                    "Could not bookmark place \(place.name, privacy: .private): \(error.localizedDescription, privacy: .public)")
                failed.append(place.name)
            }
        }
        do {
            defaults.set(try JSONEncoder().encode(stored), forKey: defaultsKey)
        } catch {
            Self.log.error("Could not encode places: \(error.localizedDescription, privacy: .public)")
            report(String(localized: "Couldn’t save your Places: \(error.localizedDescription)"))
            return
        }
        if let first = failed.first {
            report(failed.count == 1
                ? String(localized: "Couldn’t save the place “\(first)”. It won’t appear the next time XZip opens.")
                : String(localized: "Couldn’t save \(failed.count) places. They won’t appear the next time XZip opens."))
        }
    }

    /// Forwards an already-localized message to whoever owns the UI.
    private func report(_ message: String) {
        onFailure?(message)
    }

    /// Add a place for `url` (defaulting the name to the folder name), returning
    /// the updated list so callers can refresh their state.
    func add(url: URL, name: String? = nil, symbol: String = "folder", to places: [Place]) -> [Place] {
        var updated = places
        updated.append(Place(name: name ?? url.lastPathComponent, url: url, symbol: symbol))
        save(updated)
        return updated
    }

    /// Remove a place, returning the updated list so callers can refresh state.
    func remove(_ place: Place, from places: [Place]) -> [Place] {
        let updated = places.filter { $0.id != place.id }
        save(updated)
        return updated
    }

    // MARK: - Defaults

    /// Downloads + Desktop are offered out of the box (mockup 1b/5a submenu).
    private static func systemDefaults() -> [Place] {
        let fm = FileManager.default
        var places: [Place] = []
        // Fixed ids: the startup-location setting stores a Place id, so these
        // defaults must keep stable identity across launches (see Place.id).
        if let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            places.append(Place(
                id: UUID(uuidString: "C6A2B7E4-5D14-4E14-9A3B-2F60D7A1B001")!,
                name: "Downloads", url: downloads, symbol: "arrow.down.circle"
            ))
        }
        if let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
            places.append(Place(
                id: UUID(uuidString: "C6A2B7E4-5D14-4E14-9A3B-2F60D7A1B002")!,
                name: "Desktop", url: desktop, symbol: "menubar.dock.rectangle"
            ))
        }
        return places
    }
}
