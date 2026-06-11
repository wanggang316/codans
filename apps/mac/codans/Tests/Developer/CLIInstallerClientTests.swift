import Foundation
import Testing
import CodansKit

@testable import Codans

/// Covers install / uninstall / probe state transitions, the script composer,
/// and the privileged-shell invocation contract. Probe uses a real filesystem
/// rooted at a fresh tmp directory; install / uninstall use
/// `RecordingPrivilegedShell` so no real `osascript` is invoked.
@MainActor
@Suite("CLIInstallerClient")
struct CLIInstallerClientTests {
  // MARK: - Fixture helpers

  private final class TempHome {
    let root: URL
    let installDir: URL
    let bundledTc: URL

    init() throws {
      let root = FileManager.default.temporaryDirectory.appending(
        component: "codans-installer-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let bundleDir = root.appending(component: "Bundle", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
      let binary = bundleDir.appending(component: "codans", directoryHint: .notDirectory)
      try Data("#!/bin/sh\n".utf8).write(to: binary)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
      let installDir = root.appending(component: "usr/local/bin", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
      self.root = root
      self.installDir = installDir
      self.bundledTc = binary
    }

    deinit {
      try? FileManager.default.removeItem(at: root)
    }

    func paths() -> CLIInstallerClient.Paths {
      let legacyDir = root.appending(component: ".local/bin", directoryHint: .isDirectory)
      return CLIInstallerClient.Paths(
        tcSymlink: installDir.appending(component: "codans", directoryHint: .notDirectory),
        legacyLocalBinTc: legacyDir.appending(component: "codans", directoryHint: .notDirectory),
        bundledTcBinary: bundledTc
      )
    }
  }

  private func makeClient(
    paths: CLIInstallerClient.Paths,
    fileSystem: CLIFilesystem = RealCLIFilesystem(),
    privilegedShell: RecordingPrivilegedShell = RecordingPrivilegedShell()
  ) -> (CLIInstallerClient, RecordingPrivilegedShell) {
    let client = CLIInstallerClient(paths: paths, fileSystem: fileSystem, privilegedShell: privilegedShell)
    return (client, privilegedShell)
  }

  private func assertInstalled(_ status: CLIInstallerClient.InstallStatus) {
    if case .installed(_, let pointsToBundle) = status {
      #expect(pointsToBundle == true)
    } else {
      Issue.record("Expected .installed, got \(status)")
    }
  }

  // MARK: - Probe

  @Test
  func probe_freshFilesystem_returnsNotInstalled() throws {
    let home = try TempHome()
    let (client, _) = makeClient(paths: home.paths())

    #expect(client.probe() == .notInstalled)
  }

  @Test
  func probe_ourSymlink_returnsInstalled() throws {
    let home = try TempHome()
    let paths = home.paths()
    try FileManager.default.createSymbolicLink(at: paths.tcSymlink, withDestinationURL: home.bundledTc)
    let (client, _) = makeClient(paths: paths)

    assertInstalled(client.probe())
  }

  @Test
  func probe_foreignFile_returnsCollision() throws {
    let home = try TempHome()
    let paths = home.paths()
    try Data("#!/bin/sh\necho foreign\n".utf8).write(to: paths.tcSymlink)
    let (client, _) = makeClient(paths: paths)

    if case .collision(let owner) = client.probe() {
      #expect(owner == paths.tcSymlink)
    } else {
      Issue.record("Expected .collision, got \(client.probe())")
    }
  }

  // MARK: - Install

  @Test
  func install_freshMachine_callsPrivilegedShellOnceWithComposedScript() throws {
    let home = try TempHome()
    let paths = home.paths()
    let (client, shell) = makeClient(paths: paths)

    let result = client.install()

    switch result {
    case .success(let status): assertInstalled(status)
    case .failure(let error): Issue.record("Install failed: \(error)")
    }
    #expect(shell.calls.count == 1)
    let script = shell.calls.first?.command ?? ""
    #expect(script.contains("set -e"))
    #expect(script.contains("mkdir -p /usr/local/bin"))
    #expect(script.contains("ln -s '\(home.bundledTc.path)' '\(paths.tcSymlink.path)'"))
    #expect(shell.calls.first?.prompt.contains("administrator access") == true)
  }

  @Test
  func install_whenAlreadyInstalled_skipsPrivilegedDialog() throws {
    let home = try TempHome()
    let paths = home.paths()
    try FileManager.default.createSymbolicLink(at: paths.tcSymlink, withDestinationURL: home.bundledTc)
    let (client, shell) = makeClient(paths: paths)

    let result = client.install()

    switch result {
    case .success(let status): assertInstalled(status)
    case .failure(let error): Issue.record("Install failed: \(error)")
    }
    #expect(shell.calls.isEmpty)
  }

  @Test
  func install_whenForeign_returnsDestinationExistsNotOurs_andSkipsDialog() throws {
    let home = try TempHome()
    let paths = home.paths()
    try Data("#!/bin/sh\necho foreign\n".utf8).write(to: paths.tcSymlink)
    let (client, shell) = makeClient(paths: paths)

    let result = client.install()

    if case .failure(.destinationExistsNotOurs(let url)) = result {
      #expect(url == paths.tcSymlink)
    } else {
      Issue.record("Expected .destinationExistsNotOurs, got \(result)")
    }
    #expect(shell.calls.isEmpty)
  }

  @Test
  func install_userCancels_returnsUserCancelled() throws {
    let home = try TempHome()
    let shell = RecordingPrivilegedShell()
    shell.result = .throwError(.userCancelled)
    let (client, _) = makeClient(paths: home.paths(), privilegedShell: shell)

    let result = client.install()

    if case .failure(.userCancelled) = result {
      // expected
    } else {
      Issue.record("Expected .userCancelled, got \(result)")
    }
  }

  @Test
  func install_scriptFailure_returnsScriptFailedWithStderr() throws {
    let home = try TempHome()
    let shell = RecordingPrivilegedShell()
    shell.result = .throwError(.scriptFailed(stderr: "ln: permission denied"))
    let (client, _) = makeClient(paths: home.paths(), privilegedShell: shell)

    let result = client.install()

    if case .failure(.scriptFailed(let stderr)) = result {
      #expect(stderr == "ln: permission denied")
    } else {
      Issue.record("Expected .scriptFailed, got \(result)")
    }
  }

  @Test
  func install_bundleMissing_returnsBundleMissing() throws {
    let home = try TempHome()
    var paths = home.paths()
    paths.bundledTcBinary = nil
    let (client, shell) = makeClient(paths: paths)

    let result = client.install()

    if case .failure(.bundleMissing) = result {
      // expected
    } else {
      Issue.record("Expected .bundleMissing, got \(result)")
    }
    #expect(shell.calls.isEmpty)
  }

  // MARK: - Uninstall

  @Test
  func uninstall_whenInstalledByUs_callsPrivilegedShellOnceWithRmScript() throws {
    let home = try TempHome()
    let paths = home.paths()
    try FileManager.default.createSymbolicLink(at: paths.tcSymlink, withDestinationURL: home.bundledTc)
    let (client, shell) = makeClient(paths: paths)

    let result = client.uninstall()

    #expect(result == .success(.notInstalled))
    #expect(shell.calls.count == 1)
    let script = shell.calls.first?.command ?? ""
    #expect(script.contains("set -e"))
    #expect(script.contains("rm '\(paths.tcSymlink.path)'"))
  }

  @Test
  func uninstall_whenNothingPresent_skipsPrivilegedDialog() throws {
    let home = try TempHome()
    let (client, shell) = makeClient(paths: home.paths())

    let result = client.uninstall()

    #expect(result == .success(.notInstalled))
    #expect(shell.calls.isEmpty)
  }

  @Test
  func uninstall_whenForeignPresent_reportsCollisionAndSkipsDialog() throws {
    let home = try TempHome()
    let paths = home.paths()
    try Data("#!/bin/sh\necho foreign\n".utf8).write(to: paths.tcSymlink)
    let (client, shell) = makeClient(paths: paths)

    let result = client.uninstall()

    if case .success(.collision(let owner)) = result {
      #expect(owner == paths.tcSymlink)
    } else {
      Issue.record("Expected collision, got \(result)")
    }
    #expect(shell.calls.isEmpty)
  }

  // MARK: - Script composers (pure-function unit tests)

  @Test
  func composeInstallScript_freshMachine_includesMkdirAndLnLine() {
    let bundled = URL(fileURLWithPath: "/Applications/Codans.app/Contents/Resources/bin/codans")
    let codans = URL(fileURLWithPath: "/usr/local/bin/codans")

    let script = CLIInstallerClient.composeInstallScript(bundled: bundled, absentPaths: [codans])

    #expect(
      script == """
        set -e
        mkdir -p /usr/local/bin
        ln -s '/Applications/Codans.app/Contents/Resources/bin/codans' '/usr/local/bin/codans'
        """)
  }

  @Test
  func composeInstallScript_withLegacyCleanup_appendsGuardedRmLine() {
    let bundled = URL(fileURLWithPath: "/Applications/Codans.app/Contents/Resources/bin/codans")
    let codans = URL(fileURLWithPath: "/usr/local/bin/codans")
    let legacyTc = URL(fileURLWithPath: "/Users/test/.local/bin/codans")

    let script = CLIInstallerClient.composeInstallScript(
      bundled: bundled,
      absentPaths: [codans],
      legacyToCleanup: [legacyTc]
    )

    #expect(
      script == """
        set -e
        mkdir -p /usr/local/bin
        ln -s '/Applications/Codans.app/Contents/Resources/bin/codans' '/usr/local/bin/codans'
        [ -L '/Users/test/.local/bin/codans' ] && [ "$(readlink '/Users/test/.local/bin/codans')" = '/Applications/Codans.app/Contents/Resources/bin/codans' ] && rm '/Users/test/.local/bin/codans' || true
        """)
  }

  @Test
  func install_includesLegacyCleanupWhenLegacyPathsAreOurs() throws {
    let home = try TempHome()
    let paths = home.paths()
    // Pre-create the legacy symlink pointing at our bundle.
    let legacyDir = paths.legacyLocalBinTc.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: paths.legacyLocalBinTc, withDestinationURL: home.bundledTc)
    let (client, shell) = makeClient(paths: paths)

    _ = client.install()

    let bundled = home.bundledTc.path
    let expected = """
      set -e
      mkdir -p /usr/local/bin
      ln -s '\(bundled)' '\(paths.tcSymlink.path)'
      [ -L '\(paths.legacyLocalBinTc.path)' ] && [ "$(readlink '\(paths.legacyLocalBinTc.path)')" = '\(bundled)' ] && rm '\(paths.legacyLocalBinTc.path)' || true
      """
    #expect(shell.calls.first?.command == expected)
  }

  @Test
  func install_skipsLegacyCleanupWhenLegacyPathsAreForeign() throws {
    let home = try TempHome()
    let paths = home.paths()
    // Pre-create a foreign regular file at the legacy path.
    let legacyDir = paths.legacyLocalBinTc.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    try Data("#!/bin/sh\necho foreign\n".utf8).write(to: paths.legacyLocalBinTc)
    let (client, shell) = makeClient(paths: paths)

    _ = client.install()

    let script = shell.calls.first?.command ?? ""
    #expect(!script.contains(paths.legacyLocalBinTc.path), "Foreign legacy entry must not appear in cleanup")
  }

  // MARK: - AppleScript source assembly

  @Test
  func composeSource_multilineCommand_usesLinefeedConcatenation() {
    // AppleScript string literals reject raw newlines; every `\n` must be
    // split out and rejoined with `& linefeed &` in the source.
    let source = AppleScriptPrivilegedShell.composeSource(
      command: "set -e\nmkdir -p /usr/local/bin\nln -s '/a' '/b'",
      prompt: "Need admin"
    )

    #expect(
      source
        == #"do shell script "set -e" & linefeed & "mkdir -p /usr/local/bin" & linefeed & "ln -s '/a' '/b'" with prompt "Need admin" with administrator privileges"#
    )
    #expect(!source.contains("\n"), "Source must contain no raw newlines — AppleScript literals reject them")
  }

  @Test
  func composeSource_escapesEmbeddedDoubleQuotes() {
    // A path containing a double-quote must be escaped or the AppleScript
    // string literal terminates early. shellEscape's single-quote wrapping
    // protects /bin/sh, but the AppleScript layer is independent.
    let source = AppleScriptPrivilegedShell.composeSource(
      command: "echo \"hi\"",
      prompt: "p"
    )

    #expect(source.contains("\\\"hi\\\""))
  }

  @Test
  func composeUninstallScript_ourSymlink_emitsRmLine() {
    let codans = URL(fileURLWithPath: "/usr/local/bin/codans")

    let script = CLIInstallerClient.composeUninstallScript(paths: [codans])

    #expect(
      script == """
        set -e
        rm '/usr/local/bin/codans'
        """)
  }
}
