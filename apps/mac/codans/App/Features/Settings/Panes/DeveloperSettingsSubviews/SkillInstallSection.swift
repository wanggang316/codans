import CodansCore
import CodansKit
import SwiftUI

/// "Agent skills" section of the Developer pane: one `InstallTargetRow`
/// per agent target with the agent's mark and an Install / Uninstall
/// button. Installing is the user's call per agent; nothing is linked
/// automatically. Mirrors `codans skill install --target <agent>`. The
/// footer reveals the bundled skill for anyone who prefers to copy it by
/// hand.
struct SkillInstallSection: View {
  @State var model: SkillInstallModel
  @Environment(DeveloperPaneDependencies.self) private var deps

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "Install the bundled skill into an agent's skill folder so it learns the `codans` CLI; updating the app updates the skill."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(model.rows) { row in
          SkillTargetRow(
            row: row,
            install: { model.install(row) },
            uninstall: { model.uninstall(row) }
          )
        }
      }
      if model.rows.isEmpty, model.lastError == nil {
        Text("No skills are bundled with this build.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let error = model.lastError {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(.red)
            .accessibilityHidden(true)
          Text(error)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 6))
      }
      if let bundled = model.rows.first?.skill.path {
        RevealInFinderButton {
          deps.revealInFinder(URL(fileURLWithPath: bundled, isDirectory: true))
        }
        .help("Show the bundled skill folder, for installing it by hand.")
      }
    }
    .task { model.refresh() }
  }
}

private struct SkillTargetRow: View {
  let row: SkillInstallModel.Row
  let install: () -> Void
  let uninstall: () -> Void

  var body: some View {
    InstallTargetRow(
      title: row.target.displayName,
      subtitle: row.directory,
      tint: tint,
      statusText: statusText,
      icon: { logo },
      actions: { actionButton }
    )
  }

  /// Brand mark for the agents that have one; the shared folder gets the
  /// same sparkles glyph the Agents View uses for "an agent".
  @ViewBuilder
  private var logo: some View {
    let size = InstallTargetRow<EmptyView, EmptyView>.iconSize
    switch row.target {
    case .claude:
      AgentLogoView(kind: .claudeCode, size: size, tint: .primary)
    case .codex:
      AgentLogoView(kind: .codex, size: size, tint: .primary)
    case .agents:
      AgentLogoView(icon: .symbol("sparkles"), size: size, tint: .primary)
    }
  }

  @ViewBuilder
  private var actionButton: some View {
    switch row.status {
    case .missing, .otherVersion:
      Button("Install", action: install)
        .buttonStyle(.borderedProminent)
    case .installed:
      Button("Uninstall", action: uninstall)
        .buttonStyle(.bordered)
    case .conflict:
      Button("Install", action: install)
        .buttonStyle(.borderedProminent)
        .disabled(true)
        .help("Something that is not a Codans skill is already at this path; remove it first.")
    }
  }

  private var statusText: String {
    switch row.status {
    case .installed: return "installed"
    case .missing: return "not installed"
    case .otherVersion: return "installed from another build"
    case .conflict: return "path occupied by something else"
    }
  }

  private var tint: Color {
    switch row.status {
    case .installed: return .green
    case .missing: return .secondary
    case .otherVersion, .conflict: return .orange
    }
  }
}
