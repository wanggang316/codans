import ComposableArchitecture
import SwiftUI

/// Presents `RemoteConnectionSheet` off the sidebar store. Extracted into a
/// `ViewModifier` (applied as a single `.modifier(...)`) so the sidebar's
/// large `body` stays within the Swift type-checker's inference budget — an
/// inline `.sheet` with binding + scope closures pushed it over the limit.
struct RemoteConnectionSheetPresenter: ViewModifier {
  @Bindable var store: StoreOf<HierarchySidebarFeature>

  func body(content: Content) -> some View {
    content.sheet(
      isPresented: Binding(
        get: { store.remoteConnectionSheet != nil },
        set: { isPresented in
          if !isPresented {
            store.send(.remoteConnectionSheet(.cancelButtonTapped))
          }
        }
      )
    ) {
      if let childStore = store.scope(
        state: \.remoteConnectionSheet,
        action: \.remoteConnectionSheet
      ) {
        RemoteConnectionSheet(store: childStore)
          .interactiveDismissDisabled(store.remoteConnectionSheet?.isConnecting ?? false)
      }
    }
  }
}

/// SwiftUI sheet for `RemoteConnectionFeature`. Header error banner, host /
/// port / username / remote-path fields, an in-flight spinner, and a Cancel /
/// Connect footer. Mirrors `CloneRepoSheet`'s shape so the two Add Project
/// surfaces feel consistent. Auth is delegated to the user's SSH config +
/// agent — the sheet never asks for a password or key.
struct RemoteConnectionSheet: View {
  @Bindable var store: StoreOf<RemoteConnectionFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Connect to Server")
        .font(.headline)

      if let error = store.errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Host or SSH alias").font(.callout)
        TextField(
          "example.com or my-server",
          text: Binding(
            get: { store.hostDraft },
            set: { store.send(.hostChanged($0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .disabled(store.isConnecting)
      }

      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Username").font(.callout)
          TextField(
            "optional",
            text: Binding(
              get: { store.usernameDraft },
              set: { store.send(.usernameChanged($0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .disabled(store.isConnecting)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("Port").font(.callout)
          TextField(
            "22",
            text: Binding(
              get: { store.portDraft },
              set: { store.send(.portChanged($0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 80)
          .disabled(store.isConnecting)
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Remote path").font(.callout)
        TextField(
          "~/project or /srv/app",
          text: Binding(
            get: { store.pathDraft },
            set: { store.send(.pathChanged($0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .disabled(store.isConnecting)
      }

      Text("Authentication uses your SSH config and agent.")
        .font(.caption)
        .foregroundStyle(.secondary)

      if store.isConnecting {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Connecting…")
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
        .disabled(store.isConnecting)

        Button("Connect") {
          store.send(.connectButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          store.isConnecting
            || store.hostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || store.pathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
      }
    }
    .padding(20)
    .frame(width: 460)
  }
}
