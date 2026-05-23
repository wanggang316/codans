import SwiftUI
import TouchCodeCore

/// M6.1 — `tc` CLI install status card. Hosts its own state because the view
/// owns transient install/uninstall progress; persisted bookkeeping
/// (`lastInstallAttemptAt`) flows through `SettingsStore.mutateDeveloper` on
/// every attempt.
struct CLIInstallStatusCard: View {
  let installer: CLIInstallerClient
  let settingsStore: SettingsStore

  @Environment(DeveloperPaneDependencies.self) private var deps
  @State private var status: CLIInstallerClient.InstallStatus = .unknown
  @State private var lastError: CLIInstallerClient.CLIInstallError?
  @State private var isBusy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      actionRow
      if let error = lastError {
        ErrorRow(error: error)
      }
    }
    .task { refreshStatus() }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("`tc` command-line tool")
        .font(.headline)
      Text(statusDetail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var statusDetail: String {
    switch status {
    case .unknown:
      return "Checking install status…"
    case .notInstalled:
      return
        "Not installed. Click Install to symlink `\(commandName)` into /usr/local/bin (requires admin password)."
    case .installed(let url, _):
      return "Installed at \(url.path). `\(commandName)` is reachable from any shell."
    case .collision(let owner):
      return
        "Another file is at \(owner.path). TouchCode will not overwrite a tool it did not install."
    case .failed:
      return "Last attempt failed. Click Retry to try again."
    }
  }

  private var commandName: String {
    installer.paths.primaryCommandName
  }

  // MARK: - Action row

  @ViewBuilder
  private var actionRow: some View {
    HStack(spacing: 12) {
      primaryButton
      if case .installed = status {
        Button {
          deps.revealInFinder(installer.paths.tcSymlink)
        } label: {
          Label("Reveal in Finder", systemImage: "folder")
        }
        .buttonStyle(.bordered)
      }
      if isBusy {
        ProgressView().controlSize(.small)
      }
      Spacer(minLength: 0)
      StatusPill(status: status)
    }
  }

  @ViewBuilder
  private var primaryButton: some View {
    switch status {
    case .notInstalled, .unknown:
      Button("Install", action: performInstall)
        .buttonStyle(.borderedProminent)
        .disabled(isBusy)
    case .installed:
      Button("Uninstall", action: performUninstall)
        .buttonStyle(.bordered)
        .disabled(isBusy)
    case .collision:
      Button("Retry", action: performInstall)
        .buttonStyle(.bordered)
        .disabled(isBusy)
    case .failed:
      Button("Retry", action: performInstall)
        .buttonStyle(.borderedProminent)
        .disabled(isBusy)
    }
  }

  // MARK: - Actions

  private func refreshStatus() {
    status = installer.probe()
    if case .failed(let error, _) = status {
      lastError = error
    } else {
      lastError = nil
    }
  }

  private func performInstall() {
    isBusy = true
    defer { isBusy = false }
    recordAttempt()
    switch installer.install() {
    case .success(let new):
      status = new
      lastError = nil
    case .failure(let error):
      status = .failed(error, lastAttempt: Date())
      lastError = error
    }
  }

  private func performUninstall() {
    isBusy = true
    defer { isBusy = false }
    recordAttempt()
    switch installer.uninstall() {
    case .success(let new):
      status = new
      lastError = nil
    case .failure(let error):
      status = .failed(error, lastAttempt: Date())
      lastError = error
    }
  }

  private func recordAttempt() {
    settingsStore.mutateDeveloper { dev in
      dev.cli.lastInstallAttemptAt = Date()
    }
  }
}

// MARK: - Status pill

private struct StatusPill: View {
  let status: CLIInstallerClient.InstallStatus

  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(tint)
        .frame(width: 8, height: 8)
      Text(label)
        .font(.caption)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(tint.opacity(0.12), in: .capsule)
    .foregroundStyle(.secondary)
    .accessibilityLabel("tc status: \(label)")
  }

  private var label: String {
    switch status {
    case .unknown: return "Checking"
    case .notInstalled: return "Not installed"
    case .installed: return "Installed"
    case .collision: return "Collision"
    case .failed: return "Failed"
    }
  }

  private var tint: Color {
    switch status {
    case .unknown: return .secondary
    case .notInstalled: return .secondary
    case .installed: return .green
    case .collision: return .orange
    case .failed: return .red
    }
  }
}

// MARK: - Error row

private struct ErrorRow: View {
  let error: CLIInstallerClient.CLIInstallError

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.red)
        .accessibilityHidden(true)
      Text(error.localizedDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(8)
    .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 6))
  }
}
