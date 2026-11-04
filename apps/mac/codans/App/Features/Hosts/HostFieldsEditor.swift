import CodansCore
import SwiftUI

/// The Host, Username, Port, Name, and Icon fields of a Host form. Shared by the
/// Settings › Hosts editor and the "New Host…" entry of Connect to Server, so
/// both forms show the same fields in the same order.
struct HostFieldsEditor: View {
  let draft: HostDraft
  let isDisabled: Bool
  let onAddressChanged: (String) -> Void
  let onUsernameChanged: (String) -> Void
  let onPortChanged: (String) -> Void
  let onNameChanged: (String) -> Void
  let onIconChanged: (HostIcon) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      field(
        "Host", prompt: "IP, hostname, or ~/.ssh/config alias",
        text: draft.address, onChange: onAddressChanged
      )

      HStack(alignment: .top, spacing: 12) {
        field("Username", prompt: "optional", text: draft.username, onChange: onUsernameChanged)
        field("Port", prompt: "22", text: draft.port, onChange: onPortChanged)
          .frame(width: 80)
      }

      field(
        "Name", prompt: "optional, shown in the sidebar",
        text: draft.name, onChange: onNameChanged
      )

      VStack(alignment: .leading, spacing: 4) {
        Text("Icon").font(.callout)
        HostIconPicker(icon: draft.icon ?? .fallback, onChange: onIconChanged)
          .disabled(isDisabled)
      }
    }
  }

  private func field(
    _ title: String,
    prompt: String,
    text: String,
    onChange: @escaping (String) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.callout)
      TextField(prompt, text: Binding(get: { text }, set: onChange))
        .textFieldStyle(.roundedBorder)
        .disabled(isDisabled)
    }
  }
}

/// A native menu of the Host icons, with a checkmark on `icon` and each
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
    .labelsHidden()
    .fixedSize()
  }
}
