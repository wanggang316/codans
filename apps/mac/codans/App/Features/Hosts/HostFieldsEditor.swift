import CodansCore
import SwiftUI

/// The Host, Username, Port, Name, and Icon rows of a grouped Host form.
/// Shared by the Settings › Hosts editor and the "New Host…" entry of Connect
/// to Server, so both forms show the same rows in the same order. Place it
/// inside a `Section` of a `.grouped` `Form`.
struct HostFieldsEditor: View {
  let draft: HostDraft
  let isDisabled: Bool
  let onAddressChanged: (String) -> Void
  let onUsernameChanged: (String) -> Void
  let onPortChanged: (String) -> Void
  let onNameChanged: (String) -> Void
  let onIconChanged: (HostIcon) -> Void

  var body: some View {
    Group {
      field("Host", prompt: "IP, hostname, or ssh alias", text: draft.address, onChange: onAddressChanged)
      field("Username", prompt: "optional", text: draft.username, onChange: onUsernameChanged)
      field("Port", prompt: "22", text: draft.port, onChange: onPortChanged)
      field("Name", prompt: "optional, shown in sidebar", text: draft.name, onChange: onNameChanged)
      HostIconPicker(icon: draft.icon ?? .fallback, onChange: onIconChanged)
    }
    .disabled(isDisabled)
  }

  private func field(
    _ title: String,
    prompt: String,
    text: String,
    onChange: @escaping (String) -> Void,
  ) -> some View {
    TextField(title, text: Binding(get: { text }, set: onChange), prompt: Text(verbatim: prompt))
  }
}

/// A native "Icon" menu of the Host icons, with a checkmark on `icon` and each
/// item's symbol next to its name.
struct HostIconPicker: View {
  let icon: HostIcon
  let onChange: (HostIcon) -> Void

  var body: some View {
    Picker("Icon", selection: Binding(get: { icon }, set: onChange)) {
      ForEach(HostIcon.allCases) { icon in
        Label(icon.displayName, systemImage: icon.systemImage).tag(icon)
      }
    }
    .pickerStyle(.menu)
  }
}
