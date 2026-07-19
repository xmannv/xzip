import SwiftUI
import AppKit
import UniformTypeIdentifiers
import XZIPCore

/// User preferences, persisted via `@AppStorage` (UserDefaults).
///
/// Design: five tabs matching the design spec (mockup 1g) — General, Compress,
/// Extract, Formats, Presets. Defaults live in `XZIPDefaults` (single source of
/// truth for keys + fallbacks) so `CompressionOptions`/`ExtractionOptions` can
/// read the same settings without duplicating keys. "Advanced lives here, not in
/// the toolbar."
struct XZIPSettingsView: View {
    var model: AppModel?

    var body: some View {
        TabView {
            GeneralSettingsTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            CompressSettingsTab()
                .tabItem { Label("Compress", systemImage: "archivebox") }
            ExtractSettingsTab()
                .tabItem { Label("Extract", systemImage: "arrow.down.doc") }
            FormatsSettingsTab()
                .tabItem { Label("Formats", systemImage: "doc.badge.gearshape") }
            PresetsSettingsTab(model: model)
                .tabItem { Label("Presets", systemImage: "slider.horizontal.3") }
            ShortcutsSettingsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 440)
        .padding(XZIPSpace.lg)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    var model: AppModel?
    @AppStorage(XZIPDefaults.startupLocation) private var startupLocation = ""
    @AppStorage(XZIPDefaults.defaultFormat) private var defaultFormat = CompressionFormat.zip
    @AppStorage(XZIPDefaults.afterExtract) private var afterExtract = AfterExtractAction.reveal
    @AppStorage(XZIPDefaults.moveToTrashAfterExtract) private var moveToTrash = false
    @AppStorage(XZIPDefaults.quarantineApps) private var quarantineApps = true
    // Stored in the App Group suite (not standard defaults) so the sandboxed
    // FinderSync extension reads the same value.
    @AppStorage(XZIPDefaults.showFinderContextMenu, store: XZIPAppGroup.defaults) private var showFinderMenu = true
    @AppStorage(XZIPDefaults.appLanguage) private var appLanguage = AppLanguage.system
    /// Set once the user changes the language picker, revealing the relaunch
    /// prompt (the switch only fully applies on relaunch).
    @State private var languageChanged = false
    @AppStorage(XZIPDefaults.foldersFirst) private var foldersFirst = true
    @AppStorage(XZIPDefaults.showNotifications) private var showNotifications = true

    private var places: [Place] { model?.places ?? [] }

    /// Coerce a stale selection (the chosen Place was removed) back to
    /// "Start Screen" so the picker never shows an empty selection.
    private var startupSelection: Binding<String> {
        Binding(
            get: { places.contains { $0.id.uuidString == startupLocation } ? startupLocation : "" },
            set: { startupLocation = $0 }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("When XZip opens, show", selection: startupSelection) {
                    Text("Start Screen").tag("")
                    ForEach(places) { place in
                        Text(place.name).tag(place.id.uuidString)
                    }
                }
                Picker("Default compression format", selection: $defaultFormat) {
                    ForEach(CompressionFormat.compressChoices) { Text($0.rawValue).tag($0) }
                }
                Picker("After extracting", selection: $afterExtract) {
                    ForEach(AfterExtractAction.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Move archive to Trash after extraction", isOn: $moveToTrash)
                Toggle("Show folders on top", isOn: $foldersFirst)
            }
            Section {
                Toggle("Show notifications when operations finish", isOn: $showNotifications)
                Toggle("Quarantine apps extracted from archives", isOn: $quarantineApps)
                Toggle("Show XZip in Finder context menu", isOn: $showFinderMenu)
            }
            Section {
                Picker("Language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                if languageChanged {
                    HStack {
                        Text("Relaunch to apply the new language.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch Now") { AppLanguage.relaunch() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: appLanguage) { _, newValue in
            newValue.apply()
            languageChanged = true
        }
    }
}

// MARK: - Compress

private struct CompressSettingsTab: View {
    @AppStorage(XZIPDefaults.defaultLevel) private var defaultLevel = CompressionLevel.balanced
    @AppStorage(XZIPDefaults.excludeMacNoise) private var excludeMacNoise = true
    @AppStorage(XZIPDefaults.preserveTimestamps) private var preserveTimestamps = true

    var body: some View {
        Form {
            Picker("Default compression level", selection: $defaultLevel) {
                ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Exclude Mac-specific files (.DS_Store, resource forks)", isOn: $excludeMacNoise)
            Toggle("Preserve timestamps", isOn: $preserveTimestamps)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Extract

private struct ExtractSettingsTab: View {
    @AppStorage(XZIPDefaults.conflictPolicy) private var conflictPolicy = ConflictPolicy.ask
    @AppStorage(XZIPDefaults.requireAuthToReveal) private var requireAuthToReveal = true
    @AppStorage(XZIPDefaults.clearClipboard) private var clearClipboard = true

    var body: some View {
        Form {
            Picker("When a file already exists", selection: $conflictPolicy) {
                ForEach(ConflictPolicy.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Require authentication to reveal passwords", isOn: $requireAuthToReveal)
            Toggle("Clear clipboard 30 seconds after copying a password", isOn: $clearClipboard)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

/// Customizable keyboard shortcuts. Each row records a new chord into the
/// `@AppStorage`-backed store, which `XZIPCommands` reads live.
private struct ShortcutsSettingsTab: View {
    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    ShortcutRow(action: action)
                }
            } footer: {
                Text("Click a shortcut, then press the new key combination. Press Escape to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Reset All to Defaults") {
                    ShortcutAction.allCases.forEach { ShortcutStore.reset($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One editable shortcut row. Binds the recorder to the persisted value.
private struct ShortcutRow: View {
    let action: ShortcutAction
    @AppStorage private var raw: String

    init(action: ShortcutAction) {
        self.action = action
        _raw = AppStorage(wrappedValue: action.defaultShortcut.rawValue, action.defaultsKey)
    }

    var body: some View {
        HStack {
            Text(action.title)
            Spacer()
            ShortcutRecorder(shortcut: Binding(
                get: { Shortcut(rawValue: raw) ?? action.defaultShortcut },
                set: { raw = $0.rawValue }
            ))
            .frame(width: 120, height: 24)
            Button {
                raw = action.defaultShortcut.rawValue
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Reset to default")
        }
    }
}

// MARK: - Formats

private struct FormatsSettingsTab: View {
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                Text("Set XZip as the default app for archives.")
                    .foregroundStyle(.secondary)
                ForEach(CompressionFormat.allCases) { format in
                    HStack {
                        FileTypeIcon(ext: format.fileExtension)
                        Text(format.rawValue)
                        Spacer()
                        Button("Set as Default") { setDefault(for: format) }
                            .controlSize(.small)
                            .disabled(uttype(for: format) == nil)
                    }
                }
            } footer: {
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Map a format to its system content type via its file extension. Compound
    /// extensions (tar.gz) resolve on the last component (gz), which is the
    /// container macOS actually keys the default handler on.
    private func uttype(for format: CompressionFormat) -> UTType? {
        let ext = (format.fileExtension as NSString).pathExtension.isEmpty
            ? format.fileExtension
            : (format.fileExtension as NSString).pathExtension
        return UTType(filenameExtension: ext)
    }

    /// Ask LaunchServices to make XZip the default for this type. macOS may show
    /// its own confirmation; the async call completes once the user responds.
    private func setDefault(for format: CompressionFormat) {
        guard let type = uttype(for: format) else { return }
        let appURL = Bundle.main.bundleURL
        Task {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
                status = String(localized: "XZip is now the default for \(format.rawValue).")
            } catch {
                status = String(localized: "Couldn't set default for \(format.rawValue): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Presets

private struct PresetsSettingsTab: View {
    var model: AppModel?

    var body: some View {
        if let model {
            PresetsList(model: model)
        } else {
            ContentUnavailableView("Presets", systemImage: "slider.horizontal.3",
                                   description: Text("Open the main window to manage presets."))
        }
    }
}

private struct PresetsList: View {
    @Bindable var model: AppModel

    /// Sheet payload. An id not yet present in `model.presets` means "add" flow.
    @State private var editingPreset: ArchivePreset?
    @State private var isAddingPassword = false

    var body: some View {
        Form {
            Section {
                if model.presets.isEmpty {
                    Text("No presets").foregroundStyle(.secondary)
                }
                ForEach(model.presets) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name).font(.body)
                            Text(preset.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editingPreset = preset }
                            .controlSize(.small)
                        Button("Remove", role: .destructive) {
                            model.deletePreset(id: preset.id)
                        }
                        .controlSize(.small)
                    }
                }
                .onDelete { indexSet in
                    model.presets.remove(atOffsets: indexSet)
                    model.savePresets()
                }
            } header: {
                HStack {
                    Text("Presets")
                    Spacer()
                    if model.presets.isEmpty {
                        Button("Restore Defaults") { model.restoreDefaultPresets() }
                            .controlSize(.small)
                    }
                    Button {
                        editingPreset = ArchivePreset(name: "", summary: "", format: .zip, level: .balanced)
                    } label: {
                        Label("Add Preset", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
            }
            Section {
                if model.vaultKeys.isEmpty {
                    Text("No saved passwords").foregroundStyle(.secondary)
                }
                ForEach(model.vaultKeys, id: \.self) { key in
                    SavedPasswordRow(model: model, key: key)
                }
            } header: {
                HStack {
                    Text("Saved Passwords")
                    Spacer()
                    Button {
                        isAddingPassword = true
                    } label: {
                        Label("Add Password", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingPreset) { preset in
            PresetEditorSheet(
                preset: preset,
                isNew: !model.presets.contains(where: { $0.id == preset.id })
            ) { saved in
                if model.presets.contains(where: { $0.id == saved.id }) {
                    model.updatePreset(saved)
                } else {
                    model.addPreset(saved)
                }
            }
        }
        .sheet(isPresented: $isAddingPassword) {
            AddPasswordSheet(model: model)
        }
    }
}

/// Add/edit form for one preset. On save the draft is round-tripped through the
/// core mapping so the summary and per-format capabilities (encryption, split)
/// stay consistent with what a reload from disk would produce.
private struct PresetEditorSheet: View {
    let isNew: Bool
    let onSave: (ArchivePreset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ArchivePreset
    @FocusState private var nameFocused: Bool

    init(preset: ArchivePreset, isNew: Bool, onSave: @escaping (ArchivePreset) -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        _draft = State(initialValue: preset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: XZIPSpace.lg) {
            Text(isNew ? "New Preset" : "Edit Preset")
                .font(.headline)

            Form {
                TextField("Name", text: $draft.name)
                    .focused($nameFocused)
                Picker("Format", selection: $draft.format) {
                    ForEach(CompressionFormat.compressChoices) { Text($0.rawValue).tag($0) }
                }
                Picker("Level", selection: $draft.level) {
                    ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
                }
                if draft.format.supportsEncryption {
                    Toggle("Encrypt with password", isOn: $draft.encryptionEnabled)
                }
                if draft.format.supportsSplitting {
                    HStack {
                        Toggle("Split into volumes", isOn: splitEnabled)
                        Spacer()
                        if draft.splitSizeMB != nil {
                            Picker("", selection: splitSize) {
                                Text("20 MB").tag(20)
                                Text("100 MB").tag(100)
                                Text("1 GB").tag(1000)
                                Text("4.7 GB").tag(4700)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
                TextField("Exclude patterns (comma separated)", text: $draft.excludePatterns)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(XZIPSpace.sheetPadding)
        .frame(width: 440, height: 400)
        .onAppear { nameFocused = true }
    }

    private var splitEnabled: Binding<Bool> {
        Binding(
            get: { draft.splitSizeMB != nil },
            set: { draft.splitSizeMB = $0 ? 100 : nil }
        )
    }

    private var splitSize: Binding<Int> {
        Binding(
            get: { draft.splitSizeMB ?? 100 },
            set: { draft.splitSizeMB = $0 }
        )
    }

    private func save() {
        var final = draft
        final.name = final.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.name.isEmpty else { return }
        let saved = ModelMapping.uiPreset(from: ModelMapping.corePreset(from: final))
        onSave(saved)
        dismiss()
    }
}

/// Manually add a password to the Keychain vault. Saving under a name that
/// matches an archive's file name lets it auto-unlock that archive on open;
/// any entry is also selectable from the compress sheet's "Saved" menu.
private struct AddPasswordSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var password = ""
    @State private var isRevealed = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: XZIPSpace.lg) {
            Text("Add Saved Password").font(.headline)

            TextField("Name (use an archive's file name for auto-unlock)", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)

            HStack(spacing: XZIPSpace.sm) {
                RevealablePasswordField(title: "Password", text: $password,
                                        isRevealed: $isRevealed)
                Button("Suggest") {
                    password = model.generatePassword()
                    isRevealed = true
                }
                .buttonStyle(.bordered)
            }

            if model.vaultKeys.contains(name.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Label("A password with this name already exists and will be replaced.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(XZIPColor.warning)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
        }
        .padding(XZIPSpace.sheetPadding)
        .frame(width: 440)
        .onAppear { nameFocused = true }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else { return }
        model.saveVaultPassword(password, for: trimmed)
        dismiss()
    }
}

/// One saved-password row with reveal (gated by Touch ID when the
/// `requireAuthToReveal` preference is on) and copy-to-clipboard actions.
private struct SavedPasswordRow: View {
    @Bindable var model: AppModel
    let key: String

    @AppStorage(XZIPDefaults.requireAuthToReveal) private var requireAuth = true
    @AppStorage(XZIPDefaults.clearClipboard) private var clearClipboard = true
    @State private var revealed: String?

    var body: some View {
        HStack {
            Image(systemName: "key.fill").foregroundStyle(.secondary)
            Text(key)
            if let revealed {
                Text(revealed)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(revealed == nil ? "Reveal" : "Hide") { toggleReveal() }
                .controlSize(.small)
            Button("Copy") { copy() }
                .controlSize(.small)
            Button("Remove", role: .destructive) {
                model.deleteVaultPassword(for: key)
            }
            .controlSize(.small)
        }
    }

    /// Reveal requires auth (if enabled); hiding is always free.
    private func toggleReveal() {
        if revealed != nil { revealed = nil; return }
        Task {
            guard await authorized(reason: "reveal the saved password for \(key)") else { return }
            revealed = model.vaultPassword(for: key)
        }
    }

    private func copy() {
        Task {
            guard await authorized(reason: "copy the saved password for \(key)") else { return }
            if let pwd = model.vaultPassword(for: key) {
                ClipboardService.copySecret(pwd, autoClear: clearClipboard)
            }
        }
    }

    /// Pass through when the preference is off; otherwise require Touch ID.
    private func authorized(reason: String) async -> Bool {
        guard requireAuth else { return true }
        return await AuthService.authenticate(reason: reason)
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    var body: some View {
        ScrollView {
            VStack(spacing: XZIPSpace.lg) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .padding(.top, XZIPSpace.lg)

                VStack(spacing: XZIPSpace.xs) {
                    Text("XZIP")
                        .font(.system(size: 24, weight: .bold))
                    Text("Archives, without the friction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(appVersion)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .padding(.horizontal, 80)

                VStack(spacing: XZIPSpace.sm) {
                    Text("Made with ❤️ & ☕")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        open("https://github.com/sponsors/xmannv")
                    } label: {
                        Label("Sponsor on GitHub", systemImage: "heart.fill")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, XZIPSpace.lg)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Divider()
                    .padding(.horizontal, 80)

                HStack(spacing: XZIPSpace.lg) {
                    Button {
                        open("https://github.com/xmannv/xzip")
                    } label: {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        open("https://github.com/xmannv/xzip/issues/new/choose")
                    } label: {
                        Label("Report an Issue", systemImage: "ladybug")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, XZIPSpace.lg)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    private func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Supporting enums

enum AfterExtractAction: String, CaseIterable, Identifiable {
    case reveal, open, nothing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .reveal: "Reveal in Finder"
        case .open: "Open extracted folder"
        case .nothing: "Do nothing"
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, vi
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System Default"
        case .en: "English"
        case .vi: "Tiếng Việt"
        }
    }

    /// Persist the chosen language override into `AppleLanguages`. The app reads
    /// this at launch, so the change applies consistently across the whole UI
    /// (menu bar, window chrome, and content) only after a relaunch.
    func apply() {
        switch self {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .en:
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        case .vi:
            UserDefaults.standard.set(["vi"], forKey: "AppleLanguages")
        }
    }

    /// Relaunch the app so the new language applies everywhere — menu bar,
    /// window chrome, and content — consistently, rather than only in already
    /// open SwiftUI windows.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

/// Centralized `UserDefaults` keys + typed helpers for reading persisted prefs.
enum XZIPDefaults {
    static let defaultFormat = "defaultFormat"
    static let defaultLevel = "defaultLevel"
    static let showNotifications = "showNotifications"
    static let excludeMacNoise = "excludeMacNoise"
    static let conflictPolicy = "conflictPolicy"
    static let preserveTimestamps = "preserveTimestamps"
    static let requireAuthToReveal = "requireAuthToReveal"
    static let clearClipboard = "clearClipboard"
    static let afterExtract = "afterExtract"
    static let moveToTrashAfterExtract = "moveToTrashAfterExtract"
    static let quarantineApps = "quarantineApps"
    static let showFinderContextMenu = "showFinderContextMenu"
    static let appLanguage = "appLanguage"
    static let foldersFirst = "foldersFirst"
    /// UUID string of the Place to open at launch; "" (default) = Start screen.
    static let startupLocation = "startupLocation"

    /// Whether folders sort above files (defaults to true when unset).
    static var showsFoldersFirst: Bool {
        UserDefaults.standard.object(forKey: foldersFirst) == nil
            ? true
            : UserDefaults.standard.bool(forKey: foldersFirst)
    }

    /// Read the user's saved default format (falls back to ZIP).
    static var format: CompressionFormat {
        (UserDefaults.standard.string(forKey: defaultFormat))
            .flatMap(CompressionFormat.init(rawValue:)) ?? .zip
    }

    /// Read the user's saved default compression level (falls back to balanced).
    static var level: CompressionLevel {
        guard UserDefaults.standard.object(forKey: defaultLevel) != nil else { return .balanced }
        return CompressionLevel(rawValue: UserDefaults.standard.integer(forKey: defaultLevel)) ?? .balanced
    }

    /// Whether macOS noise should be excluded (defaults to true when unset).
    static var excludesMacNoise: Bool {
        UserDefaults.standard.object(forKey: excludeMacNoise) == nil
            ? true
            : UserDefaults.standard.bool(forKey: excludeMacNoise)
    }

    /// Read the saved conflict policy (falls back to Ask when unset). Stored as
    /// the enum's `rawValue` string by the Extract settings `@AppStorage`.
    static var conflictPolicyValue: ConflictPolicy {
        (UserDefaults.standard.string(forKey: conflictPolicy))
            .flatMap(ConflictPolicy.init(rawValue:)) ?? .ask
    }

    /// What to do after a successful extraction (falls back to reveal).
    static var afterExtractAction: AfterExtractAction {
        (UserDefaults.standard.string(forKey: afterExtract))
            .flatMap(AfterExtractAction.init(rawValue:)) ?? .reveal
    }

    /// Whether to move the source archive to Trash after extraction (default false).
    static var movesToTrashAfterExtract: Bool {
        UserDefaults.standard.bool(forKey: moveToTrashAfterExtract)
    }

    /// Whether completion notifications are enabled (defaults to true when unset).
    static var showsNotifications: Bool {
        UserDefaults.standard.object(forKey: showNotifications) == nil
            ? true
            : UserDefaults.standard.bool(forKey: showNotifications)
    }

    /// Whether to preserve timestamps when compressing (defaults to true when unset).
    static var preservesTimestamps: Bool {
        UserDefaults.standard.object(forKey: preserveTimestamps) == nil
            ? true
            : UserDefaults.standard.bool(forKey: preserveTimestamps)
    }

    /// Whether extracted apps should keep the quarantine flag (defaults to true).
    static var quarantinesApps: Bool {
        UserDefaults.standard.object(forKey: quarantineApps) == nil
            ? true
            : UserDefaults.standard.bool(forKey: quarantineApps)
    }
}
