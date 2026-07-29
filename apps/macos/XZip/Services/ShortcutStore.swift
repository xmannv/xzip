import SwiftUI

/// A user-customizable keyboard shortcut: a base key plus modifier flags.
///
/// Design: `RawRepresentable` over a JSON string so it drops straight into
/// `@AppStorage`, and `Codable` for the same stored fields. `XZIPCommands`
/// reads these via `@AppStorage`, so editing one in Settings rebinds the menu
/// command live (SwiftUI re-evaluates `Commands` when the default changes).
struct Shortcut: Equatable, RawRepresentable {
    /// Single base character, lowercased (e.g. "t", "o", "0").
    var key: String
    /// `EventModifiers.rawValue` bitmask (command/shift/option/control).
    var modifiers: Int

    init(key: String, modifiers: EventModifiers) {
        self.key = key.lowercased()
        self.modifiers = modifiers.rawValue
    }

    // MARK: RawRepresentable — enables @AppStorage storage.
    //
    // NB: a plain delimited string, NOT Codable/JSON. Making `Shortcut` both
    // `Codable` and `RawRepresentable` causes infinite recursion: Swift's
    // default `RawRepresentable.encode(to:)` encodes `rawValue`, which would
    // call back into a JSON-based `rawValue`. The manual format sidesteps that.

    init?(rawValue: String) {
        let parts = rawValue.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        // Reject a corrupted persisted value with a multi-character key: a
        // >1-char key would crash `Character(key)` when building the menu's
        // KeyboardShortcut. An invalid value falls back to the action's default.
        guard parts.count == 2, parts[0].count <= 1, let mods = Int(parts[1]) else { return nil }
        self.key = String(parts[0])
        self.modifiers = mods
    }

    var rawValue: String { "\(key)|\(modifiers)" }

    // MARK: Bridges to SwiftUI + display

    var eventModifiers: EventModifiers { EventModifiers(rawValue: modifiers) }

    var keyboardShortcut: KeyboardShortcut {
        // `key.first` (never `Character(key)`) so a stray multi-character key can
        // never crash the precondition inside Character(_: String).
        KeyboardShortcut(KeyEquivalent(key.first ?? " "), modifiers: eventModifiers)
    }

    /// Finder-style glyph string, e.g. "⇧⌘T".
    var displayString: String {
        var out = ""
        let mods = eventModifiers
        if mods.contains(.control) { out += "⌃" }
        if mods.contains(.option) { out += "⌥" }
        if mods.contains(.shift) { out += "⇧" }
        if mods.contains(.command) { out += "⌘" }
        out += key.uppercased()
        return out
    }
}

/// Every command that can be rebound. `rawValue` is the persistence key suffix.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case newArchive
    case openArchive
    case extractAll
    case testArchive
    case reopenClosed
    case showQueue
    case toggleSidebar

    var id: String { rawValue }

    /// UserDefaults key (stable; do not rename without a migration).
    var defaultsKey: String { "shortcut_\(rawValue)" }

    var title: String {
        switch self {
        case .newArchive:    return String(localized: "New Archive")
        case .openArchive:   return String(localized: "Open Archive")
        case .extractAll:    return String(localized: "Extract")
        case .testArchive:   return String(localized: "Test Archive")
        case .reopenClosed:  return String(localized: "Reopen Closed Archive")
        case .showQueue:     return String(localized: "Show Queue")
        case .toggleSidebar: return String(localized: "Toggle Sidebar")
        }
    }

    /// Factory default. Reopen Closed takes the macOS-standard ⇧⌘T; Test Archive
    /// moves to ⌥⌘T to free it up.
    var defaultShortcut: Shortcut {
        switch self {
        case .newArchive:    return Shortcut(key: "n", modifiers: .command)
        case .openArchive:   return Shortcut(key: "o", modifiers: .command)
        case .extractAll:    return Shortcut(key: "e", modifiers: .command)
        case .testArchive:   return Shortcut(key: "t", modifiers: [.command, .option])
        case .reopenClosed:  return Shortcut(key: "t", modifiers: [.command, .shift])
        case .showQueue:     return Shortcut(key: "0", modifiers: .command)
        case .toggleSidebar: return Shortcut(key: "s", modifiers: [.command, .option])
        }
    }
}

/// Read/write access to the persisted shortcut map.
enum ShortcutStore {
    /// The effective shortcut for an action: the user's override, else default.
    static func current(_ action: ShortcutAction, defaults: UserDefaults = .standard) -> Shortcut {
        guard let raw = defaults.string(forKey: action.defaultsKey),
              let shortcut = Shortcut(rawValue: raw) else {
            return action.defaultShortcut
        }
        return shortcut
    }

    static func set(_ shortcut: Shortcut, for action: ShortcutAction, defaults: UserDefaults = .standard) {
        defaults.set(shortcut.rawValue, forKey: action.defaultsKey)
    }

    static func reset(_ action: ShortcutAction, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: action.defaultsKey)
    }
}
