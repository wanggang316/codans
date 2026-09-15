import AppKit
import CodansCore
import CodansKit
import Foundation
import Observation

/// Short-and-build pair rendered by the About pane and copied to the pasteboard
/// by the Diagnostics section. Kept separate from `AppState.bundleVersion()` so
/// the Developer pane stays testable without reaching into AppKit.
struct BundleVersion: Equatable, Sendable {
  var short: String
  var build: String

  /// User-facing composition. Matches the spec's `"0.x.y (Build N)"` format,
  /// and falls back to the short string alone when no build number is present
  /// so we never emit `"(Build )"`.
  var display: String {
    build.isEmpty ? short : "\(short) (Build \(build))"
  }
}

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
  let copyToPasteboard: @MainActor (String) -> Void
  let bundleVersion: @MainActor () -> BundleVersion

  init(
    installer: CLIInstallerClient,
    skillInstaller: SkillInstaller? = nil,
    revealInFinder: @escaping @MainActor (URL) -> Void,
    copyToPasteboard: @escaping @MainActor (String) -> Void,
    bundleVersion: @escaping @MainActor () -> BundleVersion
  ) {
    self.installer = installer
    self.skillInstaller = skillInstaller
    self.revealInFinder = revealInFinder
    self.copyToPasteboard = copyToPasteboard
    self.bundleVersion = bundleVersion
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
      },
      copyToPasteboard: { value in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
      },
      bundleVersion: {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return BundleVersion(short: short, build: build)
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
