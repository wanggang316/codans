import ComposableArchitecture
import SwiftUI

/// SwiftUI sheet for `CloneRepoFeature`. Header error banner, a remote-URL
/// field, a local-path field with a folder picker, an in-flight spinner,
/// and a Cancel / Clone footer. Mirrors `CreateWorktreeSheet`'s shape so
/// the two Add Project surfaces feel consistent.
struct CloneRepoSheet: View {
  @Bindable var store: StoreOf<CloneRepoFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Clone Repository")
        .font(.headline)

      if let error = store.errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Repository URL").font(.callout)
        TextField(
          "https://github.com/owner/repo.git",
          text: Binding(
            get: { store.remoteURLDraft },
            set: { store.send(.remoteURLChanged($0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .disabled(store.isCloning)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Local path").font(.callout)
        HStack(spacing: 8) {
          TextField(
            "~/repo",
            text: Binding(
              get: { store.localPathDraft },
              set: { store.send(.localPathChanged($0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .disabled(store.isCloning)
          Button("Choose…") {
            store.send(.browseTapped)
          }
          .disabled(store.isCloning)
        }
      }

      if store.isCloning {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Cloning…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      HStack {
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .disabled(store.isCloning)

        Button("Clone") {
          store.send(.cloneButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          store.isCloning
            || store.remoteURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || store.localPathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
      }
    }
    .padding(20)
    .frame(width: 460)
  }
}
