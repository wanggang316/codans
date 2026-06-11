import ComposableArchitecture
import SwiftUI

struct NewTabSheet: View {
  @Bindable var store: StoreOf<NewTabFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New Tab")
        .font(.headline)
      TextField("Tab name (optional)", text: $store.draftName)
        .textFieldStyle(.roundedBorder)
      HStack {
        Spacer()
        Button("Cancel") { store.send(.cancelButtonTapped) }
          .keyboardShortcut(.cancelAction)
        Button("Create") { store.send(.submitButtonTapped) }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 320)
  }
}
