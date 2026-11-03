import SwiftUI
import UniformTypeIdentifiers

/// Paperclip button a composer keeps at the leading edge of its controls.
struct ComposerFilePickerButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "paperclip")
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help("Insert file paths")
    .accessibilityLabel("Select files")
  }
}

extension View {
  /// The system file picker with multiple selection. Picked URLs go to
  /// `onPick`; an error shows an alert and leaves the sheet open.
  func composerFilePicker(isPresented: Binding<Bool>, onPick: @escaping ([URL]) -> Void) -> some View {
    modifier(ComposerFilePickerModifier(isPresented: isPresented, onPick: onPick))
  }
}

private struct ComposerFilePickerModifier: ViewModifier {
  @Binding var isPresented: Bool
  let onPick: ([URL]) -> Void

  @State private var showsError = false
  @State private var errorMessage = ""

  func body(content: Content) -> some View {
    content
      .fileImporter(isPresented: $isPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) {
        result in
        switch result {
        case .success(let urls):
          onPick(urls)
        case .failure(let error):
          errorMessage = error.localizedDescription
          showsError = true
        }
      }
      .alert("Could Not Select Files", isPresented: $showsError) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage)
      }
  }
}
