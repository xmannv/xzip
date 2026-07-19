import SwiftUI

/// Password prompt for opening an encrypted archive (mockup 3a). Offers to save
/// the password in the Keychain vault. A wrong password does not block the
/// queue — the operation surfaces as an error the user can retry.
struct PasswordPromptSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var enteredPassword = ""
    @State private var saveToKeychain = false
    /// Whether the password is shown in clear text (mockup 3a "Show").
    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: XZIPSpace.lg) {
            HStack(spacing: XZIPSpace.md) {
                Image(systemName: "lock.fill")
                    .font(.title)
                    .foregroundStyle(XZIPColor.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Password Required").font(.headline)
                    if let name = model.currentArchive?.name {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: XZIPSpace.sm) {
                RevealablePasswordField(title: "Password", text: $enteredPassword,
                                        isRevealed: $isRevealed, onSubmit: submit)
                    .frame(width: 260)

                if !model.vaultKeys.isEmpty {
                    Menu {
                        ForEach(model.vaultKeys, id: \.self) { key in
                            Button(key) {
                                // Gate behind authentication (Touch ID / password)
                                // so a saved password can't be filled in and then
                                // revealed on an unlocked-but-unattended Mac.
                                Task {
                                    if let pw = await model.revealVaultPassword(for: key) {
                                        enteredPassword = pw
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

            Toggle("Remember in Keychain", isOn: $saveToKeychain)
                .toggleStyle(.checkbox)
                .font(.callout)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Unlock") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(enteredPassword.isEmpty)
            }
        }
        .padding(XZIPSpace.sheetPadding)
    }

    private func submit() {
        guard !enteredPassword.isEmpty else { return }
        model.password = enteredPassword
        if saveToKeychain, let url = model.currentArchive?.url {
            model.saveVaultPassword(enteredPassword, for: model.vaultKey(for: url))
        }
        model.passwordPromptDidSubmit()
        dismiss()
    }
}
