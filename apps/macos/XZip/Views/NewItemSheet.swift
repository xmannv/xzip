import SwiftUI

/// A small name-entry sheet for the "New Folder" / "New File" toolbar actions.
/// The default name is pre-filled and selected so the user can type over it.
struct NewItemSheet: View {
    let request: NewItemRequest
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(request: NewItemRequest, onCreate: @escaping (String) -> Void) {
        self.request = request
        self.onCreate = onCreate
        _name = State(initialValue: request.defaultName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: XZIPSpace.lg) {
            Text(request.title)
                .font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(create)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(XZIPSpace.sheetPadding)
        .frame(width: 360)
        .onAppear { nameFocused = true }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
    }
}
