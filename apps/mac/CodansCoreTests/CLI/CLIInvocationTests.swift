import Foundation
import Testing

@testable import CodansCore

/// A Debug build that writes plain `codans` gets answered by the installed
/// Release app, so these pin the two rules that keep a command addressed to
/// the build that wrote it.
struct CLIInvocationTests {
  private static let bundled = URL(fileURLWithPath: "/Apps/Codans.app/Contents/Resources/bin/codans")

  @Test
  func commandNameFollowsTheBuildChannel() {
    #if DEBUG
      #expect(CLIInvocation.commandName == "codans-dev")
    #else
      #expect(CLIInvocation.commandName == "codans")
    #endif
  }

  @Test
  func prefersTheInstalledNameWhenItIsOnDisk() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("cli-invocation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let installed = directory.appendingPathComponent("codans-dev", isDirectory: false)
    try Data().write(to: installed)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)

    let command = CLIInvocation.command(
      named: "codans-dev",
      installDirectory: directory,
      bundledBinary: Self.bundled
    )
    #expect(command == "codans-dev")
  }

  @Test
  func fallsBackToTheBundledBinaryWhenNotInstalled() {
    let command = CLIInvocation.command(
      named: "codans-dev",
      installDirectory: URL(fileURLWithPath: "/nonexistent-bin", isDirectory: true),
      bundledBinary: Self.bundled
    )
    // Quoted because the path is pasted into a shell command line.
    #expect(command == ShellQuoting.quoted(Self.bundled.path))
    #expect(command.contains("Codans.app"))
  }

  @Test
  func fallsBackToTheBareNameWhenNothingIsLocatable() {
    let command = CLIInvocation.command(
      named: "codans-dev",
      installDirectory: URL(fileURLWithPath: "/nonexistent-bin", isDirectory: true),
      bundledBinary: nil
    )
    #expect(command == "codans-dev")
  }
}
