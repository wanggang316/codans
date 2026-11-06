import CodansKit
import Foundation
import Observation

/// State behind the Developer pane's skill sections: which bundled skills
/// exist and, per agent target, whether each is linked, grouped by skill. Wraps
/// `SkillInstaller` so the view only renders rows and calls two verbs; the
/// same installer backs `codans skill`, so the pane and the CLI never
/// disagree about what "installed" means.
@MainActor
@Observable
final class SkillInstallModel {
  struct Row: Identifiable, Equatable {
    let skill: SkillInstaller.BundledSkill
    let target: SkillInstaller.Target
    let directory: String
    var status: SkillInstaller.Status

    var id: String { "\(skill.id)/\(target.rawValue)" }
  }

  /// One bundled skill and its target rows: one section of the pane.
  struct SkillGroup: Identifiable, Equatable {
    let skill: SkillInstaller.BundledSkill
    var rows: [Row]

    var id: String { skill.id }
    var description: String? { SkillInstallModel.descriptions[skill.id] }
    var bundledFolder: URL { URL(fileURLWithPath: skill.path, isDirectory: true) }
  }

  /// The last failure, tied to the skill whose action caused it; `nil`
  /// `skillID` means reading the bundle itself failed.
  struct Failure: Equatable {
    let skillID: String?
    let message: String
  }

  /// One sentence per skill for the section's first line. Kept here, not
  /// read from SKILL.md, because that frontmatter is written for agent
  /// triggering and is too long for a settings caption. A skill without
  /// an entry shows only its title and rows.
  static let descriptions: [String: String] = [
    "codans-cli": "Teaches agents the `codans` CLI. Updates with the app.",
    "codans-workflow": "Teaches agents to write and run codans Agent Workflows. Updates with the app.",
  ]

  /// Sorted by skill id, as `SkillInstaller.bundledSkills()` returns them.
  private(set) var groups: [SkillGroup] = []
  private(set) var lastError: Failure?

  var rows: [Row] { groups.flatMap(\.rows) }

  private let installer: SkillInstaller

  init(installer: SkillInstaller) {
    self.installer = installer
  }

  /// Every bundled skill × every target, whether or not the agent's
  /// folder exists: the user is choosing where to install, so a target
  /// they do not have yet is still offered.
  func refresh() {
    lastError = nil
    reloadRows()
  }

  private func reloadRows() {
    do {
      let report = try installer.report(targets: SkillInstaller.Target.allCases, scope: .user, projectRoot: nil)
      groups = report.map { item in
        SkillGroup(
          skill: item.skill,
          rows: item.targets.map {
            Row(skill: item.skill, target: $0.target, directory: $0.directory, status: $0.status)
          })
      }
    } catch {
      groups = []
      lastError = Failure(skillID: nil, message: "\(error)")
    }
  }

  /// Links one skill into one target. A link to another install's copy is
  /// replaced; a foreign directory or link under the name is never touched
  /// from here — the row says so and offers Reveal instead.
  func install(_ row: Row) {
    perform(skillID: row.skill.id) {
      _ = try installer.install(
        ids: [row.skill.id], targets: [row.target], scope: .user, projectRoot: nil, force: false)
    }
  }

  func uninstall(_ row: Row) {
    perform(skillID: row.skill.id) {
      _ = try installer.uninstall(ids: [row.skill.id], targets: [row.target], scope: .user, projectRoot: nil)
    }
  }

  /// Runs one change and re-reads the rows; a failure's message stays
  /// visible until the next successful change or refresh.
  private func perform(skillID: String, _ change: () throws -> Void) {
    do {
      try change()
      lastError = nil
    } catch {
      lastError = Failure(skillID: skillID, message: "\(error)")
    }
    reloadRows()
  }
}
