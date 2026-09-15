import CodansKit
import SwiftUI

/// "Agent skills" section of the Developer pane: one row per bundled skill
/// and agent target, each with its link status and an Install / Remove
/// button. Installing is the user's call per agent; nothing is linked
/// automatically. Mirrors `codans skill install --target <agent>`.
struct SkillInstallSection: View {
  @State var model: SkillInstallModel
  @Environment(DeveloperPaneDependencies.self) private var deps

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Teach your agents the `codans` CLI")
          .font(.headline)
        Text(
          "Codans ships its agent skill inside the app. Link it into an agent's skill folder and that agent learns the CLI from the version matching this app; updating the app updates the skill."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      ForEach(model.rows) { row in
        SkillTargetRow(
          row: row,
          install: { model.install(row) },
          uninstall: { model.uninstall(row) },
          reveal: { deps.revealInFinder(URL(fileURLWithPath: row.directory, isDirectory: true)) }
        )
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
    }
    .task { model.refresh() }
  }
}

private struct SkillTargetRow: View {
  let row: SkillInstallModel.Row
  let install: () -> Void
  let uninstall: () -> Void
  let reveal: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(row.skill.id) → \(row.target.displayName)")
          .font(.body)
        Text(row.directory)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
      statusLabel
      actionButton
    }
    .accessibilityElement(children: .combine)
  }

  private var statusLabel: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(tint)
        .frame(width: 8, height: 8)
      Text(statusText)
        .font(.caption)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(tint.opacity(0.12), in: .capsule)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var actionButton: some View {
    switch row.status {
    case .missing:
      Button("Install", action: install)
        .buttonStyle(.borderedProminent)
    case .installed:
      Button("Remove", action: uninstall)
        .buttonStyle(.bordered)
    case .otherVersion:
      Button("Reinstall", action: install)
        .buttonStyle(.borderedProminent)
    case .conflict:
      Button("Reveal", action: reveal)
        .buttonStyle(.bordered)
        .help("Something that is not a Codans skill link is at this path; Codans will not replace it.")
    }
  }

  private var statusText: String {
    switch row.status {
    case .installed: return "Installed"
    case .missing: return "Not installed"
    case .otherVersion: return "Other build"
    case .conflict: return "In the way"
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
