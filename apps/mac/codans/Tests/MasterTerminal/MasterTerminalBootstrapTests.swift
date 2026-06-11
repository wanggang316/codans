import Foundation
import Testing

@testable import Codans

// Production APIs under test (`MasterTerminalBootstrap.userDirectory(...)`,
// `.ensureUserDirectory(...)`) are `@MainActor`-isolated, but the
// `codansTests` target defaults to `nonisolated`. Annotating the suite
// rather than each test keeps the nested `Fixtures` helper's `masterDir`
// (which also touches a main-actor API) compilable without extra plumbing.
@MainActor
struct MasterTerminalBootstrapTests {
  // MARK: - Helpers

  // `masterDir` calls a `@MainActor` API; pin the helper to the main actor
  // so it composes with the suite-level annotation (nested types do not
  // inherit the parent's actor isolation).
  /// Creates a temp directory layout suitable for use as `homeDirectory`,
  /// plus a Bundle whose `MasterTerminalAGENTS.md` resolves to a fixture
  /// file the test owns.
  @MainActor
  private struct Fixtures {
    let homeDir: URL
    let bundle: Bundle
    let templateBody: String

    /// Master Terminal directory that bootstrap will write into.
    var masterDir: URL {
      MasterTerminalBootstrap.userDirectory(homeDirectory: homeDir)
    }
  }

  private func makeFixtures(templateBody: String = "TEMPLATE\n") throws -> Fixtures {
    let temp = URL(
      fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
    )
    .appendingPathComponent("master-terminal-tests-\(UUID().uuidString)", isDirectory: true)
    let home = temp.appendingPathComponent("home", isDirectory: true)
    let bundleDir = temp.appendingPathComponent("bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

    let templateURL = bundleDir.appendingPathComponent("MasterTerminalAGENTS.md")
    try templateBody.write(to: templateURL, atomically: true, encoding: .utf8)

    guard let bundle = Bundle(url: bundleDir) else {
      throw TestSetupError.bundleConstructionFailed
    }
    return Fixtures(homeDir: home, bundle: bundle, templateBody: templateBody)
  }

  private enum TestSetupError: Error { case bundleConstructionFailed }

  // MARK: - Tests

  @Test
  func firstRunWritesTemplateAndSymlink() throws {
    let f = try makeFixtures(templateBody: "FIRST\n")
    defer { try? FileManager.default.removeItem(at: f.homeDir.deletingLastPathComponent()) }

    try MasterTerminalBootstrap.ensureUserDirectory(
      homeDirectory: f.homeDir, bundle: f.bundle
    )

    let agentsURL = f.masterDir.appendingPathComponent("AGENTS.md")
    let claudeURL = f.masterDir.appendingPathComponent("CLAUDE.md")

    let agentsBody = try String(contentsOf: agentsURL, encoding: .utf8)
    #expect(agentsBody == "FIRST\n")

    let attrs = try FileManager.default.attributesOfItem(atPath: claudeURL.path)
    #expect((attrs[.type] as? FileAttributeType) == .typeSymbolicLink)
    let target = try FileManager.default.destinationOfSymbolicLink(atPath: claudeURL.path)
    #expect(target == "AGENTS.md")

    // Symlink resolves to the same content.
    let claudeBody = try String(contentsOf: claudeURL, encoding: .utf8)
    #expect(claudeBody == "FIRST\n")
  }

  @Test
  func secondRunPreservesUserEdits() throws {
    let f = try makeFixtures(templateBody: "ORIG\n")
    defer { try? FileManager.default.removeItem(at: f.homeDir.deletingLastPathComponent()) }

    try MasterTerminalBootstrap.ensureUserDirectory(
      homeDirectory: f.homeDir, bundle: f.bundle
    )

    let agentsURL = f.masterDir.appendingPathComponent("AGENTS.md")
    try "MUTATED\n".write(to: agentsURL, atomically: true, encoding: .utf8)

    try MasterTerminalBootstrap.ensureUserDirectory(
      homeDirectory: f.homeDir, bundle: f.bundle
    )

    let body = try String(contentsOf: agentsURL, encoding: .utf8)
    #expect(body == "MUTATED\n")
  }

  @Test
  func claudeMdAlreadyARealFileIsLeftAlone() throws {
    let f = try makeFixtures()
    defer { try? FileManager.default.removeItem(at: f.homeDir.deletingLastPathComponent()) }

    try FileManager.default.createDirectory(
      at: f.masterDir, withIntermediateDirectories: true
    )
    let claudeURL = f.masterDir.appendingPathComponent("CLAUDE.md")
    try "USER NOTES\n".write(to: claudeURL, atomically: true, encoding: .utf8)

    try MasterTerminalBootstrap.ensureUserDirectory(
      homeDirectory: f.homeDir, bundle: f.bundle
    )

    let body = try String(contentsOf: claudeURL, encoding: .utf8)
    #expect(body == "USER NOTES\n")
    let attrs = try FileManager.default.attributesOfItem(atPath: claudeURL.path)
    #expect((attrs[.type] as? FileAttributeType) == .typeRegular)
  }

  @Test
  func danglingClaudeSymlinkIsRepairedWhenAgentsMissing() throws {
    let f = try makeFixtures(templateBody: "FRESH\n")
    defer { try? FileManager.default.removeItem(at: f.homeDir.deletingLastPathComponent()) }

    try FileManager.default.createDirectory(
      at: f.masterDir, withIntermediateDirectories: true
    )
    let claudeURL = f.masterDir.appendingPathComponent("CLAUDE.md")
    // Symlink to a not-yet-existing AGENTS.md (relative target). Path-based
    // API preserves the literal "AGENTS.md" string; URL-based would resolve
    // against the test runner's cwd and bake an absolute path.
    try FileManager.default.createSymbolicLink(
      atPath: claudeURL.path,
      withDestinationPath: "AGENTS.md"
    )

    try MasterTerminalBootstrap.ensureUserDirectory(
      homeDirectory: f.homeDir, bundle: f.bundle
    )

    // AGENTS.md was created from the template; the pre-existing symlink
    // still points at "AGENTS.md" and now resolves.
    let body = try String(contentsOf: claudeURL, encoding: .utf8)
    #expect(body == "FRESH\n")
    let target = try FileManager.default.destinationOfSymbolicLink(atPath: claudeURL.path)
    #expect(target == "AGENTS.md")
  }

  @Test
  func wrongTargetSymlinkIsReplaced() throws {
    // Pre-existing CLAUDE.md symlink points at a *different* target.
    // Bootstrap contract: after we run, CLAUDE.md → AGENTS.md regardless of
    // whatever stale link the user (or a previous version of codans)
    // left behind.
    let f = try makeFixtures(templateBody: "FRESH\n")
    defer { try? FileManager.default.removeItem(at: f.homeDir.deletingLastPathComponent()) }

    try FileManager.default.createDirectory(
      at: f.masterDir, withIntermediateDirectories: true
    )
    let claudeURL = f.masterDir.appendingPathComponent("CLAUDE.md")
    try FileManager.default.createSymbolicLink(
      atPath: claudeURL.path,
      withDestinationPath: "STALE.md"
    )

    try MasterTerminalBootstrap.ensureUserDirectory(
      homeDirectory: f.homeDir, bundle: f.bundle
    )

    let target = try FileManager.default.destinationOfSymbolicLink(atPath: claudeURL.path)
    #expect(target == "AGENTS.md")
    let body = try String(contentsOf: claudeURL, encoding: .utf8)
    #expect(body == "FRESH\n")
  }

  @Test
  func bundleMissingTemplateThrows() throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("master-terminal-tests-\(UUID().uuidString)", isDirectory: true)
    let home = temp.appendingPathComponent("home", isDirectory: true)
    let emptyBundleDir = temp.appendingPathComponent("empty-bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: emptyBundleDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    guard let emptyBundle = Bundle(url: emptyBundleDir) else {
      Issue.record("Failed to construct empty bundle")
      return
    }

    #expect(throws: MasterTerminalBootstrapError.self) {
      try MasterTerminalBootstrap.ensureUserDirectory(
        homeDirectory: home, bundle: emptyBundle
      )
    }
  }
}
