import SwiftUI

/// Password prompt for opening an encrypted archive (mockup 3a). Offers to save
/// the password in the Keychain vault.
///
/// Submitting does NOT dismiss the sheet. It stays up, showing progress, until
/// the backend rules on the password; `AppModel` lowers it once the verdict is
/// in. A wrong password therefore reports on the archive the user is looking at,
/// rather than closing the sheet and letting the next queued archive appear
/// before the failure surfaces. Cancel still closes immediately.
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
                    // Name the archive the prompt is actually about. A Finder
                    // Quick Action extracts an archive the user never opened, so
                    // showing the viewed archive's name named the wrong file.
                    if let name = model.passwordPromptArchive?.lastPathComponent {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: XZIPSpace.xs) {
                RevealablePasswordField(
                    title: "Password",
                    text: $enteredPassword,
                    isRevealed: $isRevealed,
                    onSubmit: submit
                )
                .frame(maxWidth: .infinity)

                if let message = model.passwordPromptErrorMessage {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(XZIPColor.danger)
                        .accessibilityLabel(message)
                }
            }

            Toggle("Remember in Keychain", isOn: $saveToKeychain)
                .toggleStyle(.checkbox)
                .font(.callout)

            HStack(spacing: XZIPSpace.sm) {
                if model.isVerifyingPassword {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking password…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    // Drop the pending retry: leaving it armed meant a password
                    // later entered for a DIFFERENT archive re-ran this
                    // cancelled extraction.
                    model.passwordPromptDidCancel()
                    dismiss()
                }
                Button("Unlock") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    // Blocked while checking so the same password cannot be
                    // submitted twice, which would start a second verification
                    // and orphan the first.
                    .disabled(enteredPassword.isEmpty || model.isVerifyingPassword)
            }
        }
        .padding(XZIPSpace.sheetPadding)
        .frame(width: 400)
        .onAppear {
            saveToKeychain = model.passwordPromptShouldRemember
        }
    }

    private func submit() {
        guard !enteredPassword.isEmpty, !model.isVerifyingPassword else { return }
        // The model attributes the credential (and any Keychain save) to the
        // archive the prompt was about, so this view no longer has to know which
        // archive that is — it used to guess `currentArchive`, which saved the
        // password under the wrong vault key whenever the prompt came from an
        // extraction of some other archive.
        //
        // Deliberately no `dismiss()`: the model keeps the sheet up until the
        // password has been checked, so a rejection lands here instead of behind
        // the next queued archive's prompt.
        model.passwordPromptDidSubmit(enteredPassword, saveToKeychain: saveToKeychain)
    }
}
