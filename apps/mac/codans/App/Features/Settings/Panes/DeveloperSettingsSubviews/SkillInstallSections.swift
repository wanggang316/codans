import CodansCore
import CodansKit
import SwiftUI

/// The Developer pane's skill sections: one grouped-form `Section` per
/// bundled skill, titled by the skill id (the folder name it is linked
/// as), with a one-line description, one `InstallTargetRow` per agent
/// target, and a Reveal in Finder button for that skill's bundled folder.
/// Installing is the user's call per skill and agent; nothing is linked
/// automatically. Mirrors `codans skill install <id> --target <agent>`.
/// Must be placed directly inside a `Form` so each section is a peer of
/// the pane's other sections.
struct SkillInstallSections: View {
  let model: SkillInstallModel
  @Environment(DeveloperPaneDependencies.self) private var deps

  var body: some View {
    ForEach(model.groups) { group in
      Section(group.id) {
        if let description = group.description {
          Text(LocalizedStringKey(description))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        ForEach(group.rows) { row in
          SkillTargetRow(
            row: row,
            install: { model.install(row) },
            uninstall: { model.uninstall(row) }
          )
        }
        if let error = model.lastError, error.skillID == group.id {
          SkillErrorRow(message: error.message)
        }
        RevealInFinderButton {
          deps.revealInFinder(group.bundledFolder)
        }
        .help("Show the bundled \(group.id) folder, for installing it by hand.")
      }
    }
    if model.groups.isEmpty {
      Section {
        if let error = model.lastError {
          SkillErrorRow(message: error.message)
        } else {
          Text("No skills are bundled with this build.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

private struct SkillErrorRow: View {
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.red)
        .accessibilityHidden(true)
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(8)
    .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 6))
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
