import CodansKit
import Foundation
import Observation

/// State behind the Developer pane's "Agent skills" section: which bundled
/// skills exist and, per agent target, whether each is linked. Wraps
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

  private(set) var rows: [Row] = []
  private(set) var lastError: String?

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
      rows = report.flatMap { item in
        item.targets.map { Row(skill: item.skill, target: $0.target, directory: $0.directory, status: $0.status) }
      }
    } catch {
      rows = []
      lastError = "\(error)"
    }
  }

  /// Links one skill into one target. A link to another install's copy is
  /// replaced; a foreign directory or link under the name is never touched
  /// from here — the row says so and offers Reveal instead.
  func install(_ row: Row) {
    perform {
      _ = try installer.install(
        ids: [row.skill.id], targets: [row.target], scope: .user, projectRoot: nil, force: false)
    }
  }

  func uninstall(_ row: Row) {
    perform {
      _ = try installer.uninstall(ids: [row.skill.id], targets: [row.target], scope: .user, projectRoot: nil)
    }
  }

  /// Runs one change and re-reads the rows; a failure's message stays
  /// visible until the next successful change or refresh.
  private func perform(_ change: () throws -> Void) {
    do {
      try change()
      lastError = nil
    } catch {
      lastError = "\(error)"
    }
    reloadRows()
  }
}
