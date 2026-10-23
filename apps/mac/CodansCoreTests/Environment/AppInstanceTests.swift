import Foundation
import Testing

@testable import CodansCore

/// A development build made in a linked worktree carries its own instance
/// name, and every instance-scoped path derives from it.
struct AppInstanceTests {
  @Test
  func slugAppendsTheInstanceName() {
    #expect(AppInstance.slug(channel: .development, name: nil) == "codans-dev")
    #expect(AppInstance.slug(channel: .development, name: "card-pane") == "codans-dev-card-pane")
    #expect(AppInstance.slug(channel: .release, name: nil) == "codans")
  }

  @Test
  func testRunsUseTheirOwnInstance() {
    #if DEBUG
      #expect(AppInstance.name == AppInstance.testInstanceName)
      #expect(AppInstance.slug == "codans-dev-xctest")
      #expect(AppInstance.socketPath(uid: 1234) == "/tmp/codans-dev-xctest-1234.sock")
    #else
      #expect(AppInstance.name == nil)
    #endif
    #expect(AppInstance.isTestRun(["XCTestConfigurationFilePath": "/tmp/x"]))
    #expect(!AppInstance.isTestRun([:]))
  }

  @Test(arguments: ["card-pane", "a", "fix-42", "abcdefghijklmnopqrstuvwx"])
  func acceptsShortLowercaseNames(name: String) {
    #expect(AppInstance.isValid(name))
  }

  @Test(arguments: ["", "Card", "card_pane", "-card", "card-", "a/b", "abcdefghijklmnopqrstuvwxy", "ünï"])
  func rejectsOtherNames(name: String) {
    #expect(!AppInstance.isValid(name))
  }

  @Test
  func readsTheNameFromTheAppsInfoPlist() throws {
    let app = try Self.makeApp(info: [AppInstance.infoPlistKey: "card-pane"])
    defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
    #expect(AppInstance.name(inAppAt: app) == "card-pane")
  }

  @Test
  func missingOrMalformedNamesMeanTheSharedInstance() throws {
    let plain = try Self.makeApp(info: [:])
    let malformed = try Self.makeApp(info: [AppInstance.infoPlistKey: "Not Valid"])
    defer {
      try? FileManager.default.removeItem(at: plain.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: malformed.deletingLastPathComponent())
    }
    #expect(AppInstance.name(inAppAt: plain) == nil)
    #expect(AppInstance.name(inAppAt: malformed) == nil)
  }

  @Test
  func findsTheAppOfTheEmbeddedCLIThroughASymlink() throws {
    let app = try Self.makeApp(info: [:])
    let root = app.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = app.appendingPathComponent("Contents/Resources/bin/codans-dev")
    try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: cli.path, contents: Data())
    let link = root.appendingPathComponent("codans-dev")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)

    let viaLink = AppInstance.containingApp(executable: link)
    #expect(viaLink?.resolvingSymlinksInPath().path == app.resolvingSymlinksInPath().path)
    let viaBinary = AppInstance.containingApp(executable: app.appendingPathComponent("Contents/MacOS/Codans"))
    #expect(viaBinary?.lastPathComponent == "Codans.app")
    #expect(AppInstance.containingApp(executable: URL(fileURLWithPath: "/usr/local/bin/tool")) == nil)
  }

  /// A bare `Codans.app` with the given Info.plist in a fresh temp directory.
  private static func makeApp(info: [String: Any]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let app = root.appendingPathComponent("Codans.app")
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return app
  }
}
