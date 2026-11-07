import CodansCore
import ComposableArchitecture
import SwiftUI

/// Settings → Hosts (ADR 0003). The Host list in the order of addition, with
/// add, edit, and delete. Rows are not reorderable. Delete is disabled while
/// Projects use the Host, and the row shows how many.
///
/// Reads come from `@Environment(HierarchyManager.self)` so a Host added from
/// Connect to Server shows at once; writes go through `HostsSettingsFeature`.
struct HostsSettingsView: View {
  @Bindable var store: StoreOf<HostsSettingsFeature>

  @Environment(HierarchyManager.self) private var hierarchyManager

  private var hosts: [HostRecord] {
    hierarchyManager.catalog.hosts
  }

  var body: some View {
    Form {
      Section {
        if let error = store.deleteError {
          Label(error, systemImage: "exclamationmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.red)
        }
        if hosts.isEmpty {
          Text("No hosts yet. Add one here, or connect to a server.")
            .foregroundStyle(.secondary)
        }
        ForEach(hosts) { host in
          row(for: host)
        }
        Button {
          store.send(.addButtonTapped)
        } label: {
          Label("Add Host…", systemImage: "plus")
        }
        .buttonStyle(.borderless)
      } footer: {
        Text(
          "Servers that Server projects connect to. A change to a host applies to all its "
            + "projects. A host that projects use cannot be deleted."
        )
      }
    }
    .formStyle(.grouped)
    .sheet(
      isPresented: Binding(
        get: { store.editor != nil },
        set: { if !$0 { store.send(.editor(.cancelButtonTapped)) } },
      )
    ) {
      if let editor = store.editor {
        HostEditorSheet(editor: editor) { store.send(.editor($0)) }
      }
    }
  }

  private func row(for host: HostRecord) -> some View {
    let projectCount = hierarchyManager.catalog.projectCount(onHost: host.id)
    return HStack(spacing: 10) {
      Image(systemName: host.displayIcon.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(host.displayName)
          .lineLimit(1)
        if host.displayName != host.endpoint.displayAuthority {
          Text(host.endpoint.displayAuthority)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 12)
      Text(Self.projectCountText(projectCount))
        .font(.callout)
        .foregroundStyle(.secondary)
      Button {
        store.send(.editButtonTapped(host))
      } label: {
        Image(systemName: "pencil")
          .accessibilityLabel("Edit \(host.displayName)")
      }
      .buttonStyle(.borderless)
      .help("Edit host")
      Button {
        store.send(.deleteButtonTapped(host.id))
      } label: {
        Image(systemName: "trash")
          .accessibilityLabel("Delete \(host.displayName)")
      }
      .buttonStyle(.borderless)
      .disabled(projectCount > 0)
      .help(projectCount > 0 ? "Projects use this host. Remove them first." : "Delete host")
    }
  }

  static func projectCountText(_ count: Int) -> String {
    switch count {
    case 0: return "No projects"
    case 1: return "1 project"
    default: return "\(count) projects"
    }
  }
}

/// Add / edit form for one Host record, on the shared `FormSheet` frame: one
/// section of the shared Host field rows, with the error and the edit-mode
/// note in its footer.
private struct HostEditorSheet: View {
  let editor: HostsSettingsFeature.Editor
  let send: (HostsSettingsFeature.EditorAction) -> Void

  var body: some View {
    FormSheet(
      editor.isEditing ? "Edit Host" : "Add Host",
      primaryTitle: editor.isEditing ? "Save" : "Add",
      canSubmit: !editor.draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      onCancel: { send(.cancelButtonTapped) },
      onSubmit: { send(.saveButtonTapped) },
      content: {
        Section {
          HostFieldsEditor(
            draft: editor.draft,
            isDisabled: false,
            onAddressChanged: { send(.addressChanged($0)) },
            onUsernameChanged: { send(.usernameChanged($0)) },
            onPortChanged: { send(.portChanged($0)) },
            onNameChanged: { send(.nameChanged($0)) },
            onIconChanged: { send(.iconChanged($0)) },
          )
        } footer: {
          VStack(alignment: .leading, spacing: 4) {
            if let error = editor.errorMessage {
              Text(error)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            }
            if editor.isEditing {
              Text("The change applies to all projects on this host.")
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      },
    )
  }
}
