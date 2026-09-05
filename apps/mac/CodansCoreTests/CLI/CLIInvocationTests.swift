import Foundation
import Testing

@testable import CodansCore

/// A Debug build that writes plain `codans` gets answered by the installed
/// Release app, so these pin the rules that keep a command addressed to the
/// build that wrote it.
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

  /// Builds `<root>/bin/codans` as a real executable and, when `linkName` is
  /// given, `<root>/install/<linkName>` as a symlink to it. Returns the two
  /// directories.
  private static func makeTree(
    linkName: String?,
    linkTarget: URL? = nil
  ) throws -> (install: URL, binary: URL, cleanup: () -> Void) {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("cli-invocation-\(UUID().uuidString)", isDirectory: true)
    let install = root.appendingPathComponent("install", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try fileManager.createDirectory(at: install, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
    let binary = bin.appendingPathComponent("codans", isDirectory: false)
    try Data().write(to: binary)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    if let linkName {
      try fileManager.createSymbolicLink(
        at: install.appendingPathComponent(linkName, isDirectory: false),
        withDestinationURL: linkTarget ?? binary
      )
    }
    return (install, binary, { try? fileManager.removeItem(at: root) })
  }

  @Test
  func prefersTheNameWhenTheInstalledLinkIsThisBuildsBinary() throws {
    let tree = try Self.makeTree(linkName: "codans-dev")
    defer { tree.cleanup() }
    let command = CLIInvocation.command(
      named: "codans-dev",
      installDirectory: tree.install,
      bundledBinary: tree.binary
    )
    #expect(command == "codans-dev")
  }

  @Test
  func rejectsTheNameWhenTheInstalledLinkPointsAtAnotherBuild() throws {
    // `/usr/local/bin/codans` normally links into `/Applications`. A build
    // that is not that app must not write the bare name, or the installed app
    // answers in its place.
    let other = try Self.makeTree(linkName: nil)
    defer { other.cleanup() }
    let tree = try Self.makeTree(linkName: "codans", linkTarget: other.binary)
    defer { tree.cleanup() }

    let command = CLIInvocation.command(
      named: "codans",
      installDirectory: tree.install,
      bundledBinary: tree.binary
    )
    #expect(command == ShellQuoting.quoted(tree.binary.path))
  }

  /// Nothing installed under the name means the bundle's own `bin/` — on
  /// every pane's PATH — is the only thing that name can resolve to.
  @Test
  func prefersTheNameWhenNothingIsInstalledUnderIt() throws {
    let tree = try Self.makeTree(linkName: nil)
    defer { tree.cleanup() }
    let command = CLIInvocation.command(
      named: "codans-dev",
      installDirectory: tree.install,
      bundledBinary: tree.binary
    )
    #expect(command == "codans-dev")
  }

  /// A dangling link still shadows the name in `/usr/local/bin`, so the
  /// absolute path is the only spelling that reaches this build.
  @Test
  func fallsBackToTheBundledBinaryWhenTheInstalledLinkDangles() throws {
    let tree = try Self.makeTree(
      linkName: "codans-dev",
      linkTarget: URL(fileURLWithPath: "/nonexistent/Codans.app/Contents/Resources/bin/codans")
    )
    defer { tree.cleanup() }
    let command = CLIInvocation.command(
      named: "codans-dev",
      installDirectory: tree.install,
      bundledBinary: tree.binary
    )
    // Quoted because the path is pasted into a shell command line.
    #expect(command == ShellQuoting.quoted(tree.binary.path))
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
