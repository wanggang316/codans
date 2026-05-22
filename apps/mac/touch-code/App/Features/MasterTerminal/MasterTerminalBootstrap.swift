import Foundation
import os

/// Idempotent first-run setup for the Master Terminal user directory.
///
/// On first call: creates `~/.config/touch-code/master-terminal/`, writes
/// `AGENTS.md` from the bundled template, creates `CLAUDE.md` as a symlink
/// to `AGENTS.md`. Subsequent calls are no-ops if `AGENTS.md` already
/// exists — user edits are preserved.
///
/// Members are `nonisolated` because the implementation is pure FileManager +
/// Bundle I/O with no AppKit or shared mutable state — the project-wide
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` default would otherwise force
/// disk I/O onto the main thread for no reason and block nonisolated tests
/// from calling these helpers synchronously.
public enum MasterTerminalBootstrap {
  /// `~/.config/touch-code/master-terminal/`. Stable across calls; depends only on `$HOME`.
  public nonisolated static var userDirectory: URL {
    userDirectory(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
  }

  public nonisolated static func userDirectory(homeDirectory: URL) -> URL {
    homeDirectory
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("touch-code", isDirectory: true)
      .appendingPathComponent("master-terminal", isDirectory: true)
  }

  /// Idempotent. See type doc.
  ///
  /// - Parameters:
  ///   - homeDirectory: override for tests; defaults to `$HOME`.
  ///   - bundle: source of the seed `AGENTS.md` template; defaults to `.main`.
  /// - Throws: `MasterTerminalBootstrapError.templateMissing` if the bundle
  ///   does not contain the seed resource. Any underlying `FileManager` error
  ///   is rethrown verbatim.
  public nonisolated static func ensureUserDirectory(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    bundle: Bundle = .main
  ) throws {
    let dir = userDirectory(homeDirectory: homeDirectory)
    let agentsURL = dir.appendingPathComponent("AGENTS.md", isDirectory: false)
    let claudeURL = dir.appendingPathComponent("CLAUDE.md", isDirectory: false)

    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)

    // Seed AGENTS.md only if absent. Preserves user edits across launches.
    if !fm.fileExists(atPath: agentsURL.path) {
      guard
        let templateURL = bundle.url(
          forResource: "MasterTerminalAGENTS",
          withExtension: "md"
        )
      else {
        throw MasterTerminalBootstrapError.templateMissing
      }
      let contents = try Data(contentsOf: templateURL)
      try contents.write(to: agentsURL, options: .atomic)
    }

    // Reconcile CLAUDE.md → AGENTS.md symlink. We use `destinationOfSymbolicLink`
    // as the primary discriminator because it is the only API that
    // unambiguously distinguishes a symlink (dangling or live) from a regular
    // file or absent path: it returns the link target on a symlink and throws
    // on anything else. `attributesOfItem` is documented as not-following, but
    // its behavior on dangling links is ambiguous in practice; routing through
    // it would leave a window where a dangling-symlink-to-other-target is
    // silently kept rather than repaired.
    if let existingTarget = try? fm.destinationOfSymbolicLink(atPath: claudeURL.path) {
      // Exists as a symlink. Trust it only if it already points at "AGENTS.md";
      // otherwise replace, since the bootstrap contract is that
      // CLAUDE.md → AGENTS.md is always satisfied after we run.
      if existingTarget != "AGENTS.md" {
        try fm.removeItem(at: claudeURL)
        try fm.createSymbolicLink(
          atPath: claudeURL.path,
          withDestinationPath: "AGENTS.md"
        )
      }
    } else if !fm.fileExists(atPath: claudeURL.path) {
      // Doesn't exist at all. Create the symlink. Path-based API preserves
      // the literal "AGENTS.md" string; URL-based would resolve against the
      // process cwd and bake an absolute target.
      try fm.createSymbolicLink(
        atPath: claudeURL.path,
        withDestinationPath: "AGENTS.md"
      )
    } else {
      // Exists but is not a symlink (regular file, directory). Leave alone —
      // overwriting could destroy user content.
      Logger.masterTerminal.warning(
        "CLAUDE.md exists but is not a symlink; leaving as-is at \(claudeURL.path, privacy: .public)"
      )
    }
  }
}

public enum MasterTerminalBootstrapError: Error, Equatable {
  case templateMissing
}

extension Logger {
  /// Module-shared logger for the Master Terminal feature. All feature files
  /// route through this category so the unified-logging filter
  /// `category:master-terminal` surfaces a single coherent stream.
  nonisolated static let masterTerminal = Logger(
    subsystem: "com.gumpw.touch-agent-mac",
    category: "master-terminal"
  )
}
