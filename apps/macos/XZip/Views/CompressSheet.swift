import SwiftUI

/// The New Archive compress sheet (mockup 1e/3g): destination name, format
/// segmented picker (ZIP/7Z/TAR.GZ/DMG), a Faster↔Smaller slider, an encryption
/// card with a password suggester, split-into-volumes, and the Mac-noise filter.
struct CompressSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var archiveName = "New Archive"
    @State private var isPasswordRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: XZIPSpace.lg) {
            header
            saveAsField
            formatPicker
            compressionSlider
            encryptionCard
            splitRow
            excludeRow
            footerButtons
        }
        .padding(XZIPSpace.sheetPadding)
        .frame(width: 520)
        .onChange(of: model.selectedFormat) { _, format in
            if !format.supportsEncryption {
                model.encryptionEnabled = false
            }
            if !format.supportsSplitting {
                model.splitArchiveEnabled = false
            }
        }
    }

    private var header: some View {
        HStack {
            Text("New Archive").font(.title3.weight(.bold))
            Spacer()
            Menu("Preset: \(model.selectedPreset?.name ?? "Default")") {
                ForEach(model.presets) { preset in
                    Button(preset.name) { apply(preset) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var saveAsField: some View {
        VStack(alignment: .leading, spacing: XZIPSpace.xs) {
            Text("Save As").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Archive name", text: $archiveName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: XZIPSpace.xs) {
            Text("Format").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            CompressionFormatPicker(selection: $model.selectedFormat)
        }
    }

    private var compressionSlider: some View {
        VStack(alignment: .leading, spacing: XZIPSpace.sm) {
            Text("Compression").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: XZIPSpace.md) {
                Text("Faster").font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(levelIndex) },
                        set: { model.selectedLevel = levels[Int($0.rounded())] }
                    ),
                    in: 0...Double(levels.count - 1),
                    step: 1
                )
                Text("Smaller").font(.caption).foregroundStyle(.secondary)
            }
            Text(estimate)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .disabled(model.selectedFormat == .dmg)
        .opacity(model.selectedFormat == .dmg ? 0.5 : 1)
    }

    private var encryptionCard: some View {
        VStack(alignment: .leading, spacing: XZIPSpace.md) {
            HStack {
                Toggle("Encrypt with password", isOn: $model.encryptionEnabled)
                    .toggleStyle(.switch)
                    .disabled(!model.selectedFormat.supportsEncryption)
                Spacer()
                // 7z gets real AES-256; zip deliberately stays on ZipCrypto so
                // macOS Archive Utility can still open it (see the warning below).
                if model.selectedFormat.supportsEncryption {
                    Text(model.selectedFormat == .sevenZip ? "AES-256" : "ZipCrypto")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.encryptionEnabled {
                HStack {
                    RevealablePasswordField(title: "Password", text: $model.password,
                                            isRevealed: $isPasswordRevealed)
                    Button("Suggest") {
                        model.password = model.generatePassword()
                        // Reveal it: a suggested random password is never saved to
                        // the vault, so if the user can't see it they'd lock their
                        // data behind a password they never got to record.
                        isPasswordRevealed = true
                    }
                        .buttonStyle(.bordered)
                    if !model.vaultKeys.isEmpty {
                        Menu {
                            ForEach(model.vaultKeys, id: \.self) { key in
                                Button(key) {
                                    // Gate behind authentication so a saved
                                    // password isn't loaded without the user
                                    // proving presence (Touch ID / password).
                                    Task {
                                        if let pw = await model.revealVaultPassword(for: key) {
                                            model.password = pw
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Saved", systemImage: "key.fill")
                        }
                        .fixedSize()
                    }
                }
                if model.selectedFormat == .zip {
                    Label(
                        "ZIP encryption is weaker than 7Z. Use 7Z for sensitive data.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(XZIPColor.warning)
                }
            }
        }
        .padding(XZIPSpace.md)
        .background(RoundedRectangle(cornerRadius: XZIPRadius.card).fill(Color.secondary.opacity(0.06)))
    }

    private var splitRow: some View {
        HStack {
            Toggle("Split into volumes", isOn: $model.splitArchiveEnabled)
                .toggleStyle(.switch)
                .disabled(!model.selectedFormat.supportsSplitting)
            Spacer()
            if model.splitArchiveEnabled {
                Picker("", selection: $model.splitSizeMB) {
                    Text("100 MB").tag(100)
                    Text("1 GB").tag(1000)
                    Text("4.7 GB").tag(4700)
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var excludeRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle("Exclude Mac-specific files (.DS_Store, resource forks)",
                   isOn: $model.excludeMacNoise)
                .toggleStyle(.switch)
                // hdiutil creates a DMG from a source folder and has no exclusion
                // switch. Disable the option rather than silently ignoring a
                // visible, default-ON choice.
                .disabled(model.selectedFormat == .dmg)
            if model.selectedFormat == .dmg {
                Text("Disk images preserve the source folder exactly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footerButtons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Create") {
                model.startCompression(archiveName: archiveName)
                dismiss()
                // Surface the running operation immediately: the sheet closes
                // and the main window alone gives no obvious progress feedback.
                // Deferred one turn so the popover presents after the sheet
                // has started dismissing instead of racing it.
                Task { @MainActor in model.isQueuePopoverPresented = true }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(
                model.compressionInputs.isEmpty
                    || (model.selectedFormat.supportsEncryption
                        && model.encryptionEnabled
                        && model.password.isEmpty)
            )
        }
    }

    // MARK: - Helpers

    private let levels: [CompressionLevel] = [.store, .fast, .balanced, .maximum]
    private var levelIndex: Int { levels.firstIndex(of: model.selectedLevel) ?? 2 }

    /// A rough estimated-output hint based on level (real ratios vary by data).
    private var estimate: String {
        let inputBytes = model.compressionInputs.reduce(Int64(0)) { $0 + $1.estimatedSize }
        guard inputBytes > 0 else { return String(localized: "Estimates update as you choose options") }
        let ratio: Double
        switch model.selectedLevel {
        case .store: ratio = 1.0
        case .fast: ratio = 0.75
        case .balanced: ratio = 0.6
        case .maximum: ratio = 0.45
        }
        let est = Int64(Double(inputBytes) * ratio)
        return String(localized: "Estimated output: ~\(est.xzipFileSize)")
    }

    private func apply(_ preset: ArchivePreset) {
        model.selectedPresetID = preset.id
        model.selectedFormat = preset.format
        model.selectedLevel = preset.level
        model.encryptionEnabled = preset.format.supportsEncryption && preset.encryptionEnabled
        model.splitArchiveEnabled = preset.format.supportsSplitting && preset.splitSizeMB != nil
        if let splitSizeMB = preset.splitSizeMB, preset.format.supportsSplitting {
            model.splitSizeMB = splitSizeMB
        }
    }
}
