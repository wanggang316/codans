import ComposableArchitecture
import SwiftUI

/// The dialog behind Add Remote… and a remote row's Edit button, as a
/// grouped form like the sheet it opens from: the URL and the folder it is
/// cloned into. Add / Save puts it in the list.
struct WorkspaceRemoteSourceSheetView: View {
  let store: StoreOf<CreateWorkspaceFeature>
  /// The dialog as the sheet was handed it. Only read while it closes, when
  /// the store has already dropped it: the last live copy keeps the fading
  /// sheet showing the dialog rather than an empty card.
  let opened: RemoteSourceEditor
  @State private var lastLive: RemoteSourceEditor?
  @FocusState private var isURLFocused: Bool

  var body: some View {
    content(store.remoteEditor ?? lastLive ?? opened)
      .onChange(of: store.remoteEditor) { _, editor in
        if let editor { lastLive = editor }
      }
  }

  private func content(_ editor: RemoteSourceEditor) -> some View {
    VStack(spacing: 0) {
      Form {
        Section {
          TextField(
            "URL",
            text: Binding(get: { editor.urlText }, set: { store.send(.remote(.urlChanged($0))) }),
            prompt: Text("git@github.com:org/repo.git")
          )
          .focused($isURLFocused)
          .onSubmit { store.send(.remote(.urlSubmitted)) }
          if case .remote(_, let destination) = editor.draft?.source {
            cloneDestinationRow(destination)
          }
        } header: {
          Text(editor.isNew ? "Add Remote Repository" : "Edit Remote Repository")
          Text("Cloned to this Mac, then referenced like a local repository.")
        } footer: {
          IssueList(issues: store.state.issues(inEditor: editor))
        }
        .headerProminence(.increased)
      }
      .formStyle(.grouped)
      .scrollBounceBehavior(.basedOnSize)
      bar(editor)
    }
    .frame(width: 500)
    .onAppear { isURLFocused = true }
  }

  private func cloneDestinationRow(_ destination: String) -> some View {
    LabeledContent {
      HStack(spacing: 6) {
        PathText(path: destination)
        Button {
          store.send(.remote(.chooseCloneDestinationTapped))
        } label: {
          Image(systemName: "folder")
            .accessibilityLabel("Choose Clone Location")
        }
        .buttonStyle(.borderless)
        .help("Choose the folder to clone into")
      }
    } label: {
      Text("Clone to")
      Text("Reused if already cloned there.")
    }
  }

  private func bar(_ editor: RemoteSourceEditor) -> some View {
    HStack(spacing: 8) {
      if let hint = store.state.issues(inEditor: editor).first(where: { $0.severity == .incomplete }) {
        Text(hint.message)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 12)
      Button("Cancel", role: .cancel) {
        store.send(.remote(.cancelTapped))
      }
      .keyboardShortcut(.cancelAction)
      Button(editor.isNew ? "Add" : "Save") {
        store.send(.remote(.saveTapped))
      }
      .keyboardShortcut(.defaultAction)
      .disabled(!store.state.canSave(inEditor: editor))
    }
    .padding(.horizontal, 20)
    .padding(.top, 4)
    .padding(.bottom, 20)
  }
}
