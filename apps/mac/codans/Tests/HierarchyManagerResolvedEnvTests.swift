import Foundation
import Testing
import CodansCore

@testable import Codans

struct HierarchyManagerResolvedEnvTests {
  /// Keys stripped from inherited process env so libghostty's own TERM
  /// injection wins (parent `TERM=dumb` from non-interactive launches would
  /// otherwise break TUIs like starship). `TERM_PROGRAM` and
  /// `TERM_PROGRAM_VERSION` are stripped for the same reason — a parent
  /// terminal's marker must not leak into panes — before codans stamps
  /// its own product marker.
  private static let strippedKeys: Set<String> = [
    "TERM", "TERMCAP", "TERMINFO", "COLORTERM",
    "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
  ]

  /// Mirrors the version source `resolvedEnv` reads; nil under a bare
  /// `xctest` host, where the version key is omitted.
  private static let appMarketingVersion: String? =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

  private static func expectedInheritedEnv() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    for key in strippedKeys { env.removeValue(forKey: key) }
    return env
  }

  /// The always-wins keys `resolvedEnv` writes after project overrides.
  private static func alwaysInjected() -> [String: String] {
    var env = ["CODANS_SOCKET_PATH": SocketPaths.resolve()]
    env[TermProgramEnv.programKey] = TermProgramEnv.program
    if let version = appMarketingVersion {
      env[TermProgramEnv.versionKey] = version
    }
    return env
  }

  @Test
  func emptyProjectEnvVarsReturnsProcessEnvMinusTerminalVars() {
    let pid = ProjectID()
    var settings = Settings.default
    settings.projects[pid] = ProjectSettings()
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: settings)
    let expected = Self.expectedInheritedEnv().merging(Self.alwaysInjected()) { _, b in b }
    #expect(resolved == expected)
  }

  @Test
  func projectEnvVarsAreLayeredOnTopOfProcessEnv() {
    let pid = ProjectID()
    var settings = Settings.default
    settings.projects[pid] = ProjectSettings(envVars: ["MY_PROJECT_VAR": "hello"])
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: settings)
    #expect(resolved["MY_PROJECT_VAR"] == "hello")
    // Process env keys still present.
    #expect(resolved["PATH"] == ProcessInfo.processInfo.environment["PATH"])
  }

  @Test
  func projectEnvVarsOverrideProcessEnvOnCollision() {
    let pid = ProjectID()
    let collidingKey =
      ProcessInfo.processInfo.environment.keys
      .first { !Self.strippedKeys.contains($0) } ?? "HOME"
    var settings = Settings.default
    settings.projects[pid] = ProjectSettings(envVars: [collidingKey: "PROJECT_WINS"])
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: settings)
    #expect(resolved[collidingKey] == "PROJECT_WINS")
  }

  @Test
  func projectEnvVarsCanReintroduceStrippedTerminalVar() {
    let pid = ProjectID()
    var settings = Settings.default
    settings.projects[pid] = ProjectSettings(envVars: ["TERM": "screen-256color"])
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: settings)
    #expect(resolved["TERM"] == "screen-256color")
  }

  @Test
  func terminalVarsStrippedFromInheritedEnv() {
    let pid = ProjectID()
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: .default)
    // TERM_PROGRAM(_VERSION) are stripped then re-stamped with the codans
    // marker — covered by the marker tests below; the rest stay absent.
    let restampedKeys: Set<String> = [TermProgramEnv.programKey, TermProgramEnv.versionKey]
    for key in Self.strippedKeys where !restampedKeys.contains(key) {
      #expect(resolved[key] == nil)
    }
  }

  @Test
  func unknownProjectIDReturnsProcessEnvMinusTerminalVars() {
    let pid = ProjectID()  // not in settings.projects
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: .default)
    let expected = Self.expectedInheritedEnv().merging(Self.alwaysInjected()) { _, b in b }
    #expect(resolved == expected)
  }

  @Test
  func socketPathIsInjectedAfterProjectOverrides() {
    let pid = ProjectID()
    var settings = Settings.default
    settings.projects[pid] = ProjectSettings(envVars: ["CODANS_SOCKET_PATH": "/tmp/wrong.sock"])
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: settings)
    #expect(resolved["CODANS_SOCKET_PATH"] == SocketPaths.resolve())
  }

  @Test
  func termProgramMarkerIsStampedForEveryPane() {
    let pid = ProjectID()
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: .default)
    #expect(resolved[TermProgramEnv.programKey] == TermProgramEnv.program)
  }

  /// The product marker is written after project overrides — like the
  /// socket path — so a project-defined `TERM_PROGRAM` cannot misreport
  /// the hosting product.
  @Test
  func termProgramMarkerWinsOverProjectOverrides() {
    let pid = ProjectID()
    var settings = Settings.default
    settings.projects[pid] = ProjectSettings(
      envVars: [TermProgramEnv.programKey: "Apple_Terminal"]
    )
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: settings)
    #expect(resolved[TermProgramEnv.programKey] == TermProgramEnv.program)
  }

  @Test
  func termProgramVersionMatchesBundleWhenAvailable() {
    let pid = ProjectID()
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: .default)
    #expect(resolved[TermProgramEnv.versionKey] == Self.appMarketingVersion)
  }
}
