import SwiftUI

/// Password entry with an eye toggle overlaid on the trailing edge of the
/// field: hidden (SecureField) ↔ clear text (TextField).
struct RevealablePasswordField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    @Binding var isRevealed: Bool
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        Group {
            if isRevealed {
                TextField(title, text: $text)
            } else {
                SecureField(title, text: $text)
            }
        }
        .textFieldStyle(.roundedBorder)
        .onSubmit { onSubmit?() }
        .overlay(alignment: .trailing) {
            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .help(isRevealed ? "Hide password" : "Show password")
        }
    }
}
