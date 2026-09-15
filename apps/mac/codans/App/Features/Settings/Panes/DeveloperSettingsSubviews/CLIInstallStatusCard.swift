import CodansCore
import SwiftUI

/// `codans` CLI install status card, laid out like the Agent skills rows
/// below it: one `InstallTargetRow` for the symlink with an Install /
/// Uninstall button. No mark: the row is the command itself.
/// Hosts its own state because the view owns transient install/uninstall
/// progress; persisted bookkeeping (`lastInstallAttemptAt`) flows through
/// `SettingsStore.mutateDeveloper` on every attempt.
struct CLIInstallStatusCard: View {
  let installer: CLIInstallerClient
  let settingsStore: SettingsStore

  @State private var status: CLIInstallerClient.InstallStatus = .unknown
  @State private var lastError: CLIInstallerClient.CLIInstallError?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      InstallTargetRow(
        title: commandName,
        subtitle: installer.paths.tcSymlink.path,
        tint: tint,
        statusText: statusText,
        icon: { EmptyView() },
        actions: { actionButtons }
      )
      if let error = lastError {
        ErrorRow(error: error)
      }
    }
    .task { refreshStatus() }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("`codans` command-line tool")
        .font(.headline)
      Text("Install the `codans` command-line tool to control Codans from your terminal.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var commandName: String {
    installer.paths.primaryCommandName
  }

  // MARK: - Row

  @ViewBuilder
  private var actionButtons: some View {
    switch status {
    case .notInstalled, .unknown:
      Button("Install", action: performInstall)
        .buttonStyle(.borderedProminent)
    case .installed(_, true):
      Button("Uninstall", action: performUninstall)
        .buttonStyle(.bordered)
    case .installed(_, false):
      // A link to another build is simply installed again; it lands on
      // this app's binary the same way a fresh install does.
      Button("Install", action: performInstall)
        .buttonStyle(.borderedProminent)
        .help("The link points at another build of Codans; Install points it at this app.")
    case .collision:
      Button("Install", action: performInstall)
        .buttonStyle(.borderedProminent)
        .disabled(true)
        .help("Another file is at this path; Codans will not overwrite a tool it did not install.")
    case .failed:
      Button("Retry", action: performInstall)
        .buttonStyle(.borderedProminent)
    }
  }

  private var statusText: String {
    switch status {
    case .unknown: return "checking"
    case .notInstalled: return "not installed"
    case .installed(_, true): return "installed"
    case .installed(_, false): return "installed from another build"
    case .collision: return "path occupied by something else"
    case .failed: return "last attempt failed"
    }
  }

  private var tint: Color {
    switch status {
    case .unknown, .notInstalled: return .secondary
    case .installed(_, true): return .green
    case .installed(_, false), .collision: return .orange
    case .failed: return .red
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
