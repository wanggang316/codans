import CodansCore
import ComposableArchitecture
import SwiftUI

/// Presents `RemoteConnectionSheet` off the sidebar store. Extracted into a
/// `ViewModifier` (applied as a single `.modifier(...)`) so the sidebar's
/// large `body` stays within the Swift type-checker's inference budget — an
/// inline `.sheet` with binding + scope closures pushed it over the limit.
struct RemoteConnectionSheetPresenter: ViewModifier {
  @Bindable var store: StoreOf<HierarchySidebarFeature>

  func body(content: Content) -> some View {
    content.childSheet(
      store.scope(state: \.remoteConnectionSheet, action: \.remoteConnectionSheet),
      onDismiss: { store.send(.remoteConnectionSheet(.cancelButtonTapped)) },
      content: { childStore in
        RemoteConnectionSheet(store: childStore)
          .interactiveDismissDisabled(store.remoteConnectionSheet?.isConnecting ?? false)
      }
    )
  }
}

/// SwiftUI sheet for `RemoteConnectionFeature`. Header error banner, the Host
/// picker (Host list + "New Host…"), the Host fields when "New Host…" is
/// selected, the remote path, an in-flight spinner, and a Cancel / Connect
/// footer. Mirrors `CloneRepoSheet`'s shape so the two Add Project surfaces
/// feel consistent. Auth is delegated to the user's SSH config + agent — the
/// sheet never asks for a password or key.
struct RemoteConnectionSheet: View {
  @Bindable var store: StoreOf<RemoteConnectionFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(store.isEditing ? "Edit Server Connection" : "Connect to Server")
        .font(.headline)

      if let error = store.errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Host").font(.callout)
        hostPicker
      }

      if store.isNewHost {
        HostFieldsEditor(
          draft: store.newHost,
          isDisabled: store.isConnecting,
          onAddressChanged: { store.send(.addressChanged($0)) },
          onUsernameChanged: { store.send(.usernameChanged($0)) },
          onPortChanged: { store.send(.portChanged($0)) },
          onNameChanged: { store.send(.nameChanged($0)) }
        )
        .padding(.leading, 12)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Path").font(.callout)
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

      Text(footnote)
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

        Button(store.isEditing ? "Save" : "Connect") {
          store.send(.connectButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!store.canConnect)
      }
    }
    .padding(20)
    .frame(width: 460)
  }

  private var footnote: String {
    let auth = "Authentication uses your SSH config and agent."
    return store.isNewHost ? "The new host is added to Settings › Hosts. \(auth)" : auth
  }

  /// The Host list in its order, then "New Host…".
  private var hostPicker: some View {
    Picker(
      "Host",
      selection: Binding(
        get: { store.hostChoice },
        set: { store.send(.hostChoiceChanged($0)) }
      )
    ) {
      ForEach(store.hosts) { host in
        Text(Self.pickerTitle(for: host))
          .tag(RemoteConnectionFeature.State.HostChoice.existing(host.id))
      }
      if !store.hosts.isEmpty {
        Divider()
      }
      Text("New Host…")
        .tag(RemoteConnectionFeature.State.HostChoice.newHost)
    }
    .labelsHidden()
    .disabled(store.isConnecting)
  }

  /// The display name, plus the address when a Name hides it.
  static func pickerTitle(for host: HostRecord) -> String {
    let authority = host.endpoint.displayAuthority
    return host.displayName == authority ? authority : "\(host.displayName) — \(authority)"
  }
}
