import CodansCore
import Foundation
import Testing

@testable import Codans

/// Every surface's environment is built here, so these pin the set of keys
/// codans injects and the precedence between them.
struct PaneEnvironmentTests {
  private static let paneID = PaneID(raw: UUID(uuidString: "0B6D6A2E-5B3C-4D1F-9E1A-000000000001")!)
  private static let zmxDir = URL(fileURLWithPath: "/tmp/zmx-test", isDirectory: true)

  @Test
  func surfaceStageAddsExactlyThePaneScopedKeys() {
    let base = ["KEEP": "me"]
    let env = PaneEnvironment.forSurface(base, paneID: Self.paneID, zmxDirectory: Self.zmxDir)
    #expect(env["KEEP"] == "me")
    #expect(env[CodansEnvironment.Key.zmxDirectory.rawValue] == "/tmp/zmx-test")
    #expect(env[CodansEnvironment.Key.zmxSession.rawValue] == "")
    #expect(env[CodansEnvironment.Key.paneID.rawValue] == Self.paneID.raw.uuidString)
    #expect(env.count == 4)
  }

  @Test
  func inheritedZmxSessionIsClearedNotForwarded() {
    // The exact failure this guards: an app started inside a zmx pane.
    let base = [CodansEnvironment.Key.zmxSession.rawValue: "parent-session"]
    let env = PaneEnvironment.forSurface(base, paneID: Self.paneID, zmxDirectory: Self.zmxDir)
    #expect(env[CodansEnvironment.Key.zmxSession.rawValue] == "")
  }

  @Test
  func baseStageStripsTerminalKeysAndLayersOverrides() {
    let inherited = ["TERM": "dumb", "TERM_PROGRAM": "Other", "PATH": "/usr/bin", "X": "inherited"]
    let env = PaneEnvironment.processBase(
      inheriting: inherited,
      overrides: ["X": "override"],
      socketPath: "/tmp/test.sock",
      cliBinary: nil,
      marketingVersion: "9.9"
    )
    #expect(env["TERM"] == nil)
    #expect(env["PATH"] == "/usr/bin")
    #expect(env["X"] == "override")
    #expect(env[TermProgramEnv.programKey] == TermProgramEnv.program)
    #expect(env[TermProgramEnv.versionKey] == "9.9")
    #expect(env[CodansEnvironment.Key.socketPath.rawValue] == "/tmp/test.sock")
  }

  @Test
  func alwaysWinsKeysCannotBeShadowedByOverrides() {
    let env = PaneEnvironment.processBase(
      inheriting: [:],
      overrides: [
        CodansEnvironment.Key.socketPath.rawValue: "/tmp/hijacked.sock",
        TermProgramEnv.programKey: "NotCodans",
      ],
      socketPath: "/tmp/real.sock",
      cliBinary: nil,
      marketingVersion: nil
    )
    #expect(env[CodansEnvironment.Key.socketPath.rawValue] == "/tmp/real.sock")
    #expect(env[TermProgramEnv.programKey] == TermProgramEnv.program)
    #expect(env[TermProgramEnv.versionKey] == nil)
  }

  @Test
  func masterTerminalParityWithAWorktreePane() {
    // The Master Terminal has no project, but its shell must see the same
    // injected set a worktree pane does, minus the worktree built-ins.
    let master = PaneEnvironment.forSurface(
      PaneEnvironment.processBase(
        inheriting: [:], overrides: [:], socketPath: "/tmp/s.sock", cliBinary: nil, marketingVersion: nil),
      paneID: Self.paneID,
      zmxDirectory: Self.zmxDir
    )
    let expected: Set<String> = [
      CodansEnvironment.Key.socketPath.rawValue,
      TermProgramEnv.programKey,
      CodansEnvironment.Key.zmxDirectory.rawValue,
      CodansEnvironment.Key.zmxSession.rawValue,
      CodansEnvironment.Key.paneID.rawValue,
    ]
    #expect(Set(master.keys) == expected)
  }

  @Test
  func bundledCLIGoesFirstOnPATHAndIsExportedAbsolutely() {
    let cli = URL(fileURLWithPath: "/Apps/Codans.app/Contents/Resources/bin/codans")
    let env = PaneEnvironment.processBase(
      inheriting: ["PATH": "/usr/local/bin:/usr/bin"],
      overrides: [:],
      socketPath: "/tmp/s.sock",
      cliBinary: cli,
      marketingVersion: nil
    )
    #expect(env["PATH"] == "/Apps/Codans.app/Contents/Resources/bin:/usr/local/bin:/usr/bin")
    #expect(env[CodansEnvironment.Key.cli.rawValue] == cli.path)
  }

  @Test
  func aProjectsOwnPATHStillGetsThisAppsCLIInFront() {
    // Overrides are layered before the always-wins keys, so a project that
    // rebuilds PATH cannot push the installed Release CLI ahead of ours.
    let cli = URL(fileURLWithPath: "/Apps/Codans.app/Contents/Resources/bin/codans")
    let env = PaneEnvironment.processBase(
      inheriting: ["PATH": "/usr/bin"],
      overrides: ["PATH": "/opt/homebrew/bin:/usr/local/bin"],
      socketPath: "/tmp/s.sock",
      cliBinary: cli,
      marketingVersion: nil
    )
    #expect(env["PATH"] == "/Apps/Codans.app/Contents/Resources/bin:/opt/homebrew/bin:/usr/local/bin")
  }

  @Test
  func prefixingPATHNeverStacksTheSameDirectory() {
    // A pane spawned from inside a pane inherits a PATH that already carries
    // the entry; it must move to the front once, not accumulate.
    #expect(
      PaneEnvironment.prefixingPath("/usr/bin:/x/bin:/usr/local/bin", with: "/x/bin")
        == "/x/bin:/usr/bin:/usr/local/bin")
    #expect(PaneEnvironment.prefixingPath(nil, with: "/x/bin") == "/x/bin")
    #expect(PaneEnvironment.prefixingPath("", with: "/x/bin") == "/x/bin")
  }
}
