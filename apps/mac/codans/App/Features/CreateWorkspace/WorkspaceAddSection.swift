import ComposableArchitecture
import SwiftUI

/// The form's last section: add a repository from the open projects, from a
/// folder on disk, or from a remote URL that will be cloned.
struct WorkspaceAddSection: View {
  let store: StoreOf<CreateWorkspaceFeature>

  var body: some View {
    Section {
      if !store.availableCandidates.isEmpty {
        LabeledContent("Open project") {
          Menu("Choose…") {
            ForEach(store.availableCandidates) { candidate in
              Button(candidate.name) {
                store.send(.addProjectTapped(candidate.id))
              }
            }
          }
          .fixedSize()
        }
      }
      LabeledContent("Folder on disk") {
        Button("Choose…") {
          store.send(.addFolderTapped)
        }
      }
      LabeledContent {
        HStack(spacing: 8) {
          TextField(
            "Remote URL",
            text: Binding(get: { store.remoteURLDraft }, set: { store.send(.remoteURLDraftChanged($0)) }),
            prompt: Text("git@github.com:org/repo.git")
          )
          .labelsHidden()
          .onSubmit { store.send(.addRemoteURLSubmitted) }
          Button("Add") {
            store.send(.addRemoteURLSubmitted)
          }
          .disabled(store.remoteURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      } label: {
        Text("Remote URL")
        Text("Cloned before checkout.")
      }
    } header: {
      Text(store.isAddMode ? "Repository" : "Add Repository")
    } footer: {
      footer
    }
  }

  @ViewBuilder
  private var footer: some View {
    if store.isResolvingAdd {
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Checking the folder…").foregroundStyle(.secondary)
      }
    } else if let issue = store.addIssue {
      Text(issue)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
