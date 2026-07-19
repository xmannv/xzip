import Foundation

/// Persists the user's favorite extraction destinations ("Places") using
/// security-scoped bookmarks so they keep working under App Sandbox.
///
/// Design: the Repository pattern over `UserDefaults`. Each place is stored as a
/// bookmark blob; resolving one returns a URL the caller must bracket with
/// `startAccessingSecurityScopedResource()`. Kept separate from `AppModel` so
/// the sandbox/bookmark details never leak into the SwiftUI layer.
struct PlacesStore {
    private let defaultsKey = "xzip.places.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A persisted place: display metadata + the security-scoped bookmark.
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
        for entry in stored {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: entry.bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                // Could not resolve THIS session (e.g. an unmounted external
                // volume). Keep the stored entry untouched so the place returns
                // when the volume is back — never silently drop it from storage.
                kept.append(entry)
                continue
            }
            resolved.append(Place(id: entry.id, name: entry.name, url: url, symbol: entry.symbol))
            // A stale-but-resolvable bookmark must be refreshed, or it decays until
            // it stops resolving and the place is lost for good.
            if isStale, let fresh = try? url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
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
        return resolved
    }

    // MARK: - Save

    /// Persist the given places, creating a security-scoped bookmark for each.
    func save(_ places: [Place]) {
        let stored: [StoredPlace] = places.compactMap { place in
            guard let bookmark = try? place.url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return nil }
            return StoredPlace(id: place.id, name: place.name, symbol: place.symbol, bookmark: bookmark)
        }
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: defaultsKey)
        }
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
