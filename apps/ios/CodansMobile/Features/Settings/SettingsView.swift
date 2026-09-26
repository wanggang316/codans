import ComposableArchitecture
import SwiftUI
import VisionKit

/// Paired Macs, connection status, and pairing, shown as a sheet from the
/// workspace toolbar. Pairing accepts the QR
/// code from the Mac's Remote Access pane, or the same code pasted as text
/// (the only way on the simulator or a device without a camera).
struct SettingsView: View {
  @Bindable var store: StoreOf<ConnectionFeature>

  @State private var pairingCode = ""
  @State private var isScanning = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        if !store.gateways.isEmpty {
          macsSection
          statusSection
        }
        pairingSection
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .sheet(isPresented: $isScanning) {
        PairingScannerSheet { code in
          isScanning = false
          store.send(.pairingCodeSubmitted(code))
        }
      }
    }
  }

  private var macsSection: some View {
    Section("Macs") {
      ForEach(store.gateways) { gateway in
        Button {
          store.send(.gatewaySelected(gateway.deviceID))
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(gateway.displayName)
                .foregroundStyle(.primary)
              Text("Paired \(gateway.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if gateway.deviceID == store.activeID {
              Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .accessibilityLabel("Active")
            }
          }
        }
        .swipeActions {
          Button("Forget", role: .destructive) { store.send(.forgetTapped(gateway.deviceID)) }
        }
      }
    }
  }

  private var statusSection: some View {
    let health = store.health
    return Section {
      ConnectionStatusView(health: health)
      if let session = store.session {
        LabeledContent("Access", value: session.permission == .interactive ? "Can send input" : "View only")
        if !session.serverVersion.isEmpty {
          LabeledContent("Codans on Mac", value: session.serverVersion)
        }
      }
      if let lastContact = health.lastContact {
        LabeledContent("Last contact") {
          Text(lastContact, format: .relative(presentation: .named))
        }
      }
      if !health.isLive, let explanation = health.explanation {
        Text(explanation)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      switch health.recovery {
      case .retry?:
        Button("Reconnect") { store.send(.connectTapped) }
      case .openSettings?:
        ConnectionRecoveryButton(recovery: .openSettings, retry: {}, pairAgain: {})
      case .pairAgain?, nil:
        // Pairing again happens in the section below.
        EmptyView()
      }
    } header: {
      Text("Connection")
    } footer: {
      Text("Access is set per device on your Mac, in Codans Settings › Remote Access.")
    }
  }

  private var pairingSection: some View {
    Section {
      if PairingScannerSheet.isAvailable {
        Button("Scan Pairing Code", systemImage: "qrcode.viewfinder") { isScanning = true }
      }
      TextField("codans-pair:…", text: $pairingCode, axis: .vertical)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(.system(.footnote, design: .monospaced))
        .lineLimit(1...4)
      HStack {
        PasteButton(payloadType: String.self) { strings in
          if let first = strings.first { pairingCode = first }
        }
        Spacer()
        Button("Pair") {
          store.send(.pairingCodeSubmitted(pairingCode))
          pairingCode = ""
        }
        .disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if let error = store.pairingError {
        Text(error)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Pair a Mac")
    } footer: {
      Text(
        "On your Mac, open Codans Settings › Remote Access, turn on Remote Access and choose Pair New Device. The code is a key to your Mac: don't share it."
      )
    }
  }
}
