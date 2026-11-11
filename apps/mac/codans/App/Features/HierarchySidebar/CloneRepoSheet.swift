import ComposableArchitecture
import SwiftUI

/// SwiftUI sheet for `CloneRepoFeature`, on the shared `FormSheet` frame:
/// a remote-URL row and a local-path row with a folder picker, the clone
/// error in the section footer (git's raw output under a classified
/// message), and "Cloning…" in the bottom bar. Cancel stays enabled while
/// cloning: it stops the clone.
struct CloneRepoSheet: View {
  @Bindable var store: StoreOf<CloneRepoFeature>

  var body: some View {
    FormSheet(
      "Clone Repository",
      primaryTitle: "Clone",
      canSubmit: canClone,
      onCancel: { store.send(.cancelButtonTapped) },
      onSubmit: { store.send(.cloneButtonTapped) },
      content: {
        Section {
          TextField(
            "Repository URL",
            text: Binding(
              get: { store.remoteURLDraft },
              set: { store.send(.remoteURLChanged($0)) },
            ),
            prompt: Text(verbatim: "https://github.com/owner/repo.git"),
          )
          LabeledContent("Local path") {
            HStack(spacing: 8) {
              TextField(
                "Local path",
                text: Binding(
                  get: { store.localPathDraft },
                  set: { store.send(.localPathChanged($0)) },
                ),
                prompt: Text(verbatim: "~/repo"),
              )
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              Button("Choose…") {
                store.send(.browseTapped)
              }
            }
          }
        } footer: {
          if let error = store.errorMessage {
            VStack(alignment: .leading, spacing: 4) {
              Text(error)
                .foregroundStyle(.red)
              if let detail = store.errorDetail {
                Text(detail)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
              }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .disabled(store.isCloning)
      },
      status: {
        if store.isCloning {
          FormSheetProgress(text: "Cloning…")
        }
      },
    )
  }

  private var canClone: Bool {
    !store.isCloning
      && !store.remoteURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !store.localPathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
