import ComposableArchitecture
import SwiftUI
import VisionKit

/// Paired Macs, the connection, and pairing, as a sheet from the home
/// title menu. Pairing accepts the QR code from the Mac's Remote Access
/// pane, or the same code pasted as text (the only way on the simulator or
/// a device without a camera).
struct SettingsView: View {
  @Bindable var store: StoreOf<ConnectionFeature>
  /// Opened from "Pair New Mac…": straight to the scanner, or the code
  /// field where there is no camera.
  var startsPairing = false

  @State private var pairingCode = ""
  @State private var isScanning = false
  @FocusState private var isCodeFocused: Bool
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        if !store.gateways.isEmpty {
          macsSection
          connectionSection
        }
        pairingSection
      }
      .scrollContentBackground(.hidden)
      .background(Color.surfaceGrouped)
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .fontWeight(.semibold)
        }
      }
      .sheet(isPresented: $isScanning) {
        PairingScannerSheet { code in
          isScanning = false
          store.send(.pairingCodeSubmitted(code))
        }
      }
      .task {
        guard startsPairing else { return }
        if PairingScannerSheet.isAvailable {
          isScanning = true
        } else {
          try? await Task.sleep(for: .milliseconds(400))
          isCodeFocused = true
        }
      }
    }
  }

  private var macsSection: some View {
    Section {
      ForEach(store.gateways) { gateway in
        Button {
          store.send(.gatewaySelected(gateway.deviceID))
        } label: {
          HStack(spacing: Theme.Space.sm) {
            Image(systemName: "laptopcomputer")
              .font(.system(size: 17))
              .foregroundStyle(Color.inkSecondary)
              .frame(width: 28)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text(gateway.displayName)
                .font(.system(size: 17))
                .foregroundStyle(Color.ink)
              Text("Paired \(gateway.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.rowDetail)
                .foregroundStyle(Color.inkSecondary)
            }
            Spacer()
            if gateway.deviceID == store.activeID {
              Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.ink)
                .accessibilityLabel("Active")
            }
          }
        }
        .swipeActions {
          Button("Forget", role: .destructive) { store.send(.forgetTapped(gateway.deviceID)) }
        }
      }
    } header: {
      Text("Macs")
    }
  }

  private var connectionSection: some View {
    Section {
      NavigationLink {
        ConnectionDetailsForm(store: store)
          .navigationTitle("Connection")
          .navigationBarTitleDisplayMode(.inline)
      } label: {
        HStack {
          Text("Status")
            .foregroundStyle(Color.ink)
          Spacer()
          ConnectionStatusLine(health: store.health)
            .font(.system(size: 15))
        }
      }
    } header: {
      Text("Connection")
    } footer: {
      Text("Access is set per device on your Mac, in Codans Settings › Remote Access.")
    }
  }

  private var canPair: Bool {
    !pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var pairingSection: some View {
    Section {
      if PairingScannerSheet.isAvailable {
        Button {
          isScanning = true
        } label: {
          Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
            .foregroundStyle(Color.ink)
        }
      }
      TextField("codans-pair:…", text: $pairingCode, axis: .vertical)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(.system(size: 14, design: .monospaced))
        .lineLimit(1...4)
        .focused($isCodeFocused)
        .accessibilityIdentifier("pairing-code")
      HStack {
        PasteButton(payloadType: String.self) { strings in
          if let first = strings.first { pairingCode = first }
        }
        .buttonBorderShape(.capsule)
        .labelStyle(.titleAndIcon)
        .tint(Color.surfaceMuted)
        .foregroundStyle(Color.ink)
        Spacer()
        Button("Pair") {
          store.send(.pairingCodeSubmitted(pairingCode))
          pairingCode = ""
        }
        .buttonStyle(.inkCompact)
        .disabled(!canPair)
        .accessibilityIdentifier("pairing-submit")
      }
      if let error = store.pairingError {
        Label(error, systemImage: "exclamationmark.circle")
          .font(.system(size: 13))
          .foregroundStyle(Color.failure)
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

/// The connection to the active Mac, as a sheet from the home title menu.
struct ConnectionDetailsView: View {
  let store: StoreOf<ConnectionFeature>

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ConnectionDetailsForm(store: store)
        .navigationTitle(store.activeGateway?.displayName ?? "Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
              .fontWeight(.semibold)
          }
        }
    }
  }
}

/// What the connection is doing, what the Mac granted, and the fix when
/// there is one.
struct ConnectionDetailsForm: View {
  let store: StoreOf<ConnectionFeature>

  private func outsideAccess(session: RemoteSessionInfo?) -> String {
    if session?.route == .relay { return "Connected via relay" }
    return store.activeGateway?.relay == nil ? "Not set up" : "Ready"
  }

  var body: some View {
    let health = store.health
    Form {
      Section {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
          HStack(spacing: Theme.Space.xs) {
            StatusDot(color: health.tone.color, pulses: health.tone == .working, size: 9)
            Text(health.title)
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(Color.ink)
          }
          if !health.isLive, let explanation = health.explanation {
            Text(explanation)
              .font(.system(size: 15))
              .foregroundStyle(Color.inkSecondary)
          }
        }
        .padding(.vertical, Theme.Space.xxs)
        switch health.recovery {
        case .some(let recovery):
          ConnectionRecoveryButton(
            recovery: recovery, retry: { store.send(.connectTapped) }, pairAgain: {}
          )
          .foregroundStyle(Color.ink)
          .fontWeight(.medium)
        case nil:
          if health.isLive {
            Button("Reconnect Now") { store.send(.connectTapped) }
              .foregroundStyle(Color.ink)
          }
        }
      }

      if let session = store.session {
        Section("Mac") {
          LabeledContent("Access", value: session.permission == .interactive ? "Can send input" : "View only")
          if !session.serverVersion.isEmpty {
            LabeledContent("Codans on Mac", value: session.serverVersion)
          }
          LabeledContent("Live terminal", value: session.supportsLiveTerminal ? "Yes" : "Needs a Mac update")
        }
      }

      Section {
        LabeledContent("Outside this network", value: outsideAccess(session: store.session))
      } footer: {
        Text(
          "To reach your Mac over cellular or another network, turn on “Allow access from outside this network” in Codans Settings › Remote Access, then connect here once on the same network."
        )
      }

      if health.lastContact != nil || health.lastSyncedAt != nil {
        Section("Activity") {
          if let lastContact = health.lastContact {
            LabeledContent("Last contact") {
              Text(lastContact, format: .relative(presentation: .named))
            }
          }
          if let syncedAt = health.lastSyncedAt {
            LabeledContent("Data from") {
              Text(syncedAt, format: .relative(presentation: .named))
            }
          }
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(Color.surfaceGrouped)
    .accessibilityIdentifier("connection-details")
  }
}
