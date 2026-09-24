import AppKit
import CodansCore
import CodansIPC
import CodansRemote
import SwiftUI

/// Settings → Remote Access. The switch for the LAN gateway, the pairing
/// flow (QR code plus a copyable code, shown inline), and the list of
/// paired devices with rename, permission and revoke.
struct RemoteAccessSettingsView: View {
  let settingsStore: SettingsStore
  /// Nil until the IPC stack is up (and always under tests), in which case
  /// only the switch is shown.
  @Environment(RemoteGatewayServer.self) private var gateway: RemoteGatewayServer?

  /// The pairing currently on screen, if any.
  @State private var pairing: PairingPayload?
  @State private var pairingError: String?
  @State private var deviceToRevoke: PairedDevice?

  /// `pairing` seeds an in-progress pairing, for previews and render checks.
  init(settingsStore: SettingsStore, pairing: PairingPayload? = nil) {
    self.settingsStore = settingsStore
    _pairing = State(initialValue: pairing)
  }

  var body: some View {
    Form {
      Section {
        Toggle("Allow paired devices to connect", isOn: enabledBinding)
          .disabled(gateway?.isForcedOff ?? false)
        if let gateway {
          LabeledContent("Status", value: statusText(gateway))
        }
      } footer: {
        Text(
          "Codans on your iPhone or iPad can show agents and panes over the local network. "
            + "Connections are encrypted and only devices paired below can connect."
        )
        .foregroundStyle(.secondary)
      }

      if let gateway {
        Section("Pair a Device") {
          pairingSection(gateway)
        }
        Section("Paired Devices") {
          if gateway.devices.devices.isEmpty {
            Text("No devices paired.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(gateway.devices.devices) { device in
              PairedDeviceRow(
                device: device,
                isConnected: gateway.connectedDeviceIDs.contains(device.id),
                devices: gateway.devices,
                onRevoke: { deviceToRevoke = device }
              )
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      "Revoke \(deviceToRevoke?.name ?? "device")?",
      isPresented: Binding(get: { deviceToRevoke != nil }, set: { if !$0 { deviceToRevoke = nil } }),
      presenting: deviceToRevoke
    ) { device in
      Button("Revoke", role: .destructive) {
        gateway?.devices.revoke(device.id)
        deviceToRevoke = nil
      }
    } message: { _ in
      Text("The device is disconnected now and must be paired again to reconnect.")
    }
  }

  // MARK: - Pairing

  @ViewBuilder
  private func pairingSection(_ gateway: RemoteGatewayServer) -> some View {
    if let pairing, let device = gateway.devices.device(pairing.deviceID) {
      if device.state == .active {
        LabeledContent {
          Button("Done") { self.pairing = nil }
        } label: {
          Label("\(device.name) is paired.", systemImage: "checkmark.circle.fill")
        }
      } else {
        pendingPairing(pairing, device: device, gateway: gateway)
      }
    } else {
      LabeledContent {
        Button("Pair New Device…") { startPairing(gateway) }
          .disabled(!settingsStore.settings.remoteAccess.enabled || gateway.isForcedOff)
      } label: {
        Text("Show a code to scan with Codans on your iPhone or iPad.")
        if !settingsStore.settings.remoteAccess.enabled {
          Text("Turn on remote access first.")
        }
      }
      if let pairingError {
        Text(pairingError)
          .foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder
  private func pendingPairing(
    _ pairing: PairingPayload,
    device: PairedDevice,
    gateway: RemoteGatewayServer
  ) -> some View {
    let code = (try? pairing.encodedString()) ?? ""
    HStack(alignment: .top, spacing: 16) {
      if let image = PairingQRCode.image(for: code) {
        Image(nsImage: image)
          .interpolation(.none)
          .resizable()
          .frame(width: 180, height: 180)
          .accessibilityLabel("Pairing QR code")
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("Scan this code in Codans on your device, or copy the pairing code and paste it there.")
          .fixedSize(horizontal: false, vertical: true)
        Text("Anyone with this code can connect as this device. It expires in 10 minutes if unused.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("Copy Pairing Code") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
          }
          Button("Cancel", role: .destructive) {
            gateway.devices.revoke(device.id)
            self.pairing = nil
          }
        }
      }
    }
    Picker("Permission", selection: permissionBinding(device.id, devices: gateway.devices)) {
      ForEach(IPC.RemotePermission.allCases, id: \.self) { permission in
        Text(permission.displayName).tag(permission)
      }
    }
  }

  private func startPairing(_ gateway: RemoteGatewayServer) {
    do {
      pairing = try gateway.pairNewDevice()
      pairingError = nil
    } catch {
      pairingError = "Could not create a pairing code: \(error.localizedDescription)"
    }
  }

  // MARK: - Bindings

  private var enabledBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.remoteAccess.enabled },
      set: { enabled in
        settingsStore.setRemoteAccessEnabled(enabled)
        gateway?.setEnabled(enabled)
      }
    )
  }

  private func statusText(_ gateway: RemoteGatewayServer) -> String {
    switch gateway.status {
    case .off: return "Off"
    case .forcedOff: return "Disabled by CODANS_REMOTE_DISABLED"
    case .noDevices: return "Waiting for a paired device"
    case .starting: return "Starting…"
    case .listening: return "Listening as “\(gateway.serviceName)”"
    case .unavailable(let reason): return "Unavailable: \(reason)"
    }
  }
}

/// One paired device: editable name, permission, connection state, revoke.
private struct PairedDeviceRow: View {
  let device: PairedDevice
  let isConnected: Bool
  let devices: PairedDeviceStore
  let onRevoke: () -> Void

  @State private var draftName = ""

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        TextField("Name", text: $draftName)
          .labelsHidden()
          .textFieldStyle(.plain)
          .onSubmit(commitName)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Picker("Permission", selection: permissionBinding(device.id, devices: devices)) {
        ForEach(IPC.RemotePermission.allCases, id: \.self) { permission in
          Text(permission.displayName).tag(permission)
        }
      }
      .labelsHidden()
      .fixedSize()
      Button("Revoke…", role: .destructive, action: onRevoke)
    }
    .onAppear { draftName = device.name }
    .onChange(of: device.name) { _, name in draftName = name }
    .onDisappear(perform: commitName)
  }

  private var subtitle: String {
    if isConnected { return "Connected" }
    if device.state == .pending { return "Waiting to pair" }
    guard let lastSeen = device.lastSeenAt else { return "Never connected" }
    return "Last seen \(lastSeen.formatted(.relative(presentation: .named)))"
  }

  private func commitName() {
    guard draftName != device.name else { return }
    devices.rename(device.id, to: draftName)
    draftName = devices.device(device.id)?.name ?? device.name
  }
}

@MainActor
private func permissionBinding(_ id: UUID, devices: PairedDeviceStore) -> Binding<IPC.RemotePermission> {
  Binding(
    get: { devices.permission(for: id) ?? .readOnly },
    set: { devices.setPermission(id, to: $0) }
  )
}

extension IPC.RemotePermission {
  var displayName: String {
    switch self {
    case .readOnly: return "View only"
    case .interactive: return "View and type"
    }
  }
}
