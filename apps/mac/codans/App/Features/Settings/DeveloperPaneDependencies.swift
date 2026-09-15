import AppKit
import CodansCore
import CodansKit
import Foundation
import Observation

/// Dependency container injected into the Developer pane via `@Environment`.
/// Holding closures rather than concrete singletons makes the pane trivially
/// previewable and unit-testable — the production path wires them to
/// `AppState`, SwiftUI previews and tests stub them in place.
@MainActor
@Observable
final class DeveloperPaneDependencies {
  let installer: CLIInstallerClient
  /// Links the bundled agent skills into agent skill folders. `nil` when
  /// the bundle carries no `Resources/skills` (previews, stripped builds);
  /// the pane then hides the section.
  let skillInstaller: SkillInstaller?
  let revealInFinder: @MainActor (URL) -> Void

  init(
    installer: CLIInstallerClient,
    skillInstaller: SkillInstaller? = nil,
    revealInFinder: @escaping @MainActor (URL) -> Void
  ) {
    self.installer = installer
    self.skillInstaller = skillInstaller
    self.revealInFinder = revealInFinder
  }
}

extension DeveloperPaneDependencies {
  /// Production factory. `settingsURL` is threaded through so the Reveal-in-Finder
  /// action can materialise a missing settings file before opening Finder.
  @MainActor
  static func live(
    settingsURL: URL
  ) -> DeveloperPaneDependencies {
    DeveloperPaneDependencies(
      installer: CLIInstallerClient(),
      skillInstaller: Self.bundledSkillInstaller(),
      revealInFinder: { url in
        Self.revealInFinderEnsuringExists(url, settingsURL: settingsURL)
      }
    )
  }

  /// The installer over this bundle's `Resources/skills`, or `nil` when the
  /// folder is absent. Same location `codans skill` resolves from the CLI's
  /// own path, so the pane and the CLI always link the same copy.
  private static func bundledSkillInstaller() -> SkillInstaller? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let skills = resources.appendingPathComponent("skills", isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: skills.path, isDirectory: &isDirectory), isDirectory.boolValue
    else { return nil }
    return SkillInstaller(bundledDirectory: skills, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
  }

  /// Reveals `url` in Finder. If `url` is the canonical settings file and does
  /// not exist, materialises it through the same atomic-rename writer the live
  /// store uses — so the user sees a real file to edit rather than a dangling
  /// path. Any other URL is revealed as-is.
  @MainActor
  private static func revealInFinderEnsuringExists(
    _ url: URL,
    settingsURL: URL
  ) {
    if !FileManager.default.fileExists(atPath: url.path) {
      if url == settingsURL {
        try? AtomicFileStore.write(Settings.default, to: settingsURL)
      }
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}
