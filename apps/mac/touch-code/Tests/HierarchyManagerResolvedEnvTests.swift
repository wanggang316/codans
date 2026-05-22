import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

struct HierarchyManagerResolvedEnvTests {
  /// Keys stripped from inherited process env so libghostty's own TERM
  /// injection wins (parent `TERM=dumb` from non-interactive launches would
  /// otherwise break TUIs like starship).
  private static let strippedKeys: Set<String> = [
    "TERM", "TERMCAP", "TERMINFO", "COLORTERM",
  ]

  private static func expectedInheritedEnv() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    for key in strippedKeys { env.removeValue(forKey: key) }
    return env
  }

  @Test
  func emptyProjectEnvVarsReturnsProcessEnvMinusTerminalVars() {
    let pid = ProjectID()
    var settings = Settings.default
    settings.projects[pid] = ProjectSettings()
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: settings)
    var expected = Self.expectedInheritedEnv()
    expected["TOUCH_CODE_SOCKET_PATH"] = SocketPaths.resolve()
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
    for key in Self.strippedKeys {
      #expect(resolved[key] == nil)
    }
  }

  @Test
  func unknownProjectIDReturnsProcessEnvMinusTerminalVars() {
    let pid = ProjectID()  // not in settings.projects
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: .default)
    var expected = Self.expectedInheritedEnv()
    expected["TOUCH_CODE_SOCKET_PATH"] = SocketPaths.resolve()
    #expect(resolved == expected)
  }

  @Test
  func socketPathIsInjectedAfterProjectOverrides() {
    let pid = ProjectID()
    var settings = Settings.default
    settings.projects[pid] = ProjectSettings(envVars: ["TOUCH_CODE_SOCKET_PATH": "/tmp/wrong.sock"])
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: settings)
    #expect(resolved["TOUCH_CODE_SOCKET_PATH"] == SocketPaths.resolve())
  }
}
