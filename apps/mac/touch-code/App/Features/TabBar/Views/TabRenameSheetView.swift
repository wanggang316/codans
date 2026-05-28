import SwiftUI

/// Sheet-hosted rename editor for a single tab. A modally presented
/// card attached to the enclosing window via `.sheet(item:)`. Pre-
/// populates with the current title, commits on Return / Save,
/// discards on Esc / Cancel.
struct TabRenameSheetView: View {
  let initialName: String
  let onCommit: (String?) -> Void
  let onCancel: () -> Void

  @State private var name: String
  @FocusState private var nameFieldFocused: Bool

  init(
    initialName: String,
    onCommit: @escaping (String?) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.initialName = initialName
    self.onCommit = onCommit
    self.onCancel = onCancel
    _name = State(initialValue: initialName)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Rename Tab")
          .font(.headline)
        Text("Leave blank to restore the default tab name.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      TextField("Tab name", text: $name)
        .textFieldStyle(.roundedBorder)
        .focused($nameFieldFocused)
        .onSubmit(commit)

      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Save", action: commit)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(24)
    .frame(width: 360)
    .onAppear {
      nameFieldFocused = true
    }
  }

  private func commit() {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    onCommit(trimmed.isEmpty ? nil : trimmed)
  }
}

#if DEBUG
  #Preview {
    TabRenameSheetView(
      initialName: "Build",
      onCommit: { _ in },
      onCancel: {}
    )
  }
#endif
