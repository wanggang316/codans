import AppKit
import Foundation
import Testing
import CodansCore

@testable import Codans

/// Launch-mode branching. Drives `LiveEditorService.open` against a
/// `RecordingAppLauncher` and pins the exact tuple `(urls, appURL, arguments,
/// createsNewApplicationInstance)` handed to `NSWorkspace` for each launch mode:
///
///   - `.directory` — single-URL open, default configuration.
///   - `.applicationWithArguments` — empty URL list, `arguments=[dir]`, new instance.
///   - `.shellEditor` — descriptive throw (pending follow-up; see EditorService+Live.swift).
///
/// `.notADirectory` is also covered here since it shares the `open(directory:preferred:)`
/// entry point.
@MainActor
struct EditorServiceLaunchTests {
  // MARK: - Fixtures

  private static func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EditorServiceLaunchTests-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func stubAppURL(for id: EditorID) -> URL {
    guard let row = EditorRegistry.registry.first(where: { $0.id == id }) else {
      return URL(fileURLWithPath: "/Applications/\(id).app")
    }
    return URL(fileURLWithPath: "/Applications/\(row.displayName).app")
  }

  private static func makeService(
    installed: [EditorID]
  ) -> (service: LiveEditorService, launcher: RecordingAppLauncher) {
    var map: [String: URL] = [:]
    for id in installed {
      guard let row = EditorRegistry.registry.first(where: { $0.id == id }),
        !row.bundleIdentifier.isEmpty
      else { continue }
      map[row.bundleIdentifier] = stubAppURL(for: id)
    }
    let launcher = RecordingAppLauncher(installedApps: map)
    let service = LiveEditorService(launcher: launcher, globalDefault: { nil })
    return (service, launcher)
  }

  // MARK: - .directory

  @Test
  func directoryLaunchUsesURLListAndDefaultConfiguration() async throws {
    let dir = try Self.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (service, launcher) = Self.makeService(installed: ["vscode", "finder"])

    _ = try await service.open(directory: dir, preferred: "vscode")

    #expect(launcher.openCalls.count == 1)
    let call = try #require(launcher.openCalls.first)
    #expect(call.mode == .openURLs, ".directory must route through NSWorkspace.open(urls:…)")
    #expect(call.urls == [dir])
    #expect(call.appURL == Self.stubAppURL(for: "vscode"))
    #expect(call.arguments.isEmpty, ".directory launch must not pass arguments")
    #expect(
      call.createsNewApplicationInstance == false,
      ".directory launch must use the default OpenConfiguration (single-instance)"
    )
  }

  // MARK: - .applicationWithArguments (JetBrains family)

  @Test
  func applicationWithArgumentsLaunchRoutesThroughOpenApplicationWithDirPathArgument() async throws {
    let dir = try Self.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (service, launcher) = Self.makeService(installed: ["intellij", "finder"])

    _ = try await service.open(directory: dir, preferred: "intellij")

    #expect(launcher.openCalls.count == 1)
    let call = try #require(launcher.openCalls.first)
    #expect(
      call.mode == .openApplication,
      ".applicationWithArguments must route through NSWorkspace.openApplication(at:configuration:) — `open(urls:…)` with an empty URL list does not deliver configuration.arguments"
    )
    #expect(call.urls.isEmpty, ".applicationWithArguments carries no URL list")
    #expect(call.appURL == Self.stubAppURL(for: "intellij"))
    #expect(call.arguments == [dir.path])
    #expect(
      call.createsNewApplicationInstance == true,
      ".applicationWithArguments must set createsNewApplicationInstance=true"
    )
  }

  @Test
  func allJetBrainsIDsUseOpenApplicationBranch() async throws {
    // Table-driven: every JetBrains family entry routes through `openApplication(at:…)`
    // with the same tuple shape. Catches a regression where only IntelliJ was wired
    // correctly, and pins the NSWorkspace API so the URL-list shape cannot re-creep in.
    let jetBrainsIDs: [EditorID] = ["intellij", "webstorm", "pycharm", "rubymine", "rustrover"]
    for id in jetBrainsIDs {
      let dir = try Self.tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let (service, launcher) = Self.makeService(installed: [id, "finder"])

      _ = try await service.open(directory: dir, preferred: id)

      let call = try #require(launcher.openCalls.first, "\(id): no open call recorded")
      #expect(
        call.mode == .openApplication,
        "\(id): expected NSWorkspace.openApplication(at:configuration:)"
      )
      #expect(call.urls.isEmpty, "\(id): expected empty URL list")
      #expect(call.arguments == [dir.path], "\(id): expected [dir.path] arguments")
      #expect(
        call.createsNewApplicationInstance == true,
        "\(id): expected createsNewApplicationInstance=true"
      )
    }
  }

  // MARK: - .shellEditor (descriptive throw — Pane-aware caller is the real launcher)

  @Test
  func shellEditorThroughOpenServiceThrowsLaunchFailed() async throws {
    // `describe()` now includes `.shellEditor` so pickers can list it, but the service's
    // `(directory: URL, preferred: EditorID?)` signature still excludes the Pane/Tab
    // context the Pane primitive needs. A strict `preferred: "editor"` therefore
    // resolves through the descriptor list (no `.notInstalled`) and lands in the
    // `.shellEditor` branch of `open()`, which throws `.launchFailed` with a message
    // pointing callers at `hierarchyClient.openPane(... initialCommand: "$EDITOR")`.
    let dir = try Self.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (service, _) = Self.makeService(installed: ["finder"])

    do {
      _ = try await service.open(directory: dir, preferred: "editor")
      Issue.record(".shellEditor open should have thrown")
    } catch let error as EditorError {
      guard case .launchFailed = error else {
        Issue.record("Expected .launchFailed for shell editor open, got \(error)")
        return
      }
    } catch {
      Issue.record("Expected EditorError.launchFailed, got \(error)")
    }
  }

  // MARK: - .notADirectory

  @Test
  func openThrowsNotADirectoryWhenPathDoesNotExist() async {
    let bogusDir = URL(
      fileURLWithPath: "/tmp/this-path-does-not-exist-\(UUID().uuidString)",
      isDirectory: true
    )
    let (service, launcher) = Self.makeService(installed: ["finder"])

    do {
      _ = try await service.open(directory: bogusDir, preferred: nil)
      Issue.record("Expected .notADirectory for non-existent path")
    } catch let error as EditorError {
      guard case .notADirectory(let path) = error else {
        Issue.record("Expected .notADirectory, got \(error)")
        return
      }
      #expect(path == bogusDir.path)
    } catch {
      Issue.record("Expected EditorError.notADirectory, got \(error)")
    }

    #expect(launcher.openCalls.isEmpty, "Launcher must not be invoked on .notADirectory")
  }

  @Test
  func openThrowsNotADirectoryWhenPathIsAFile() async throws {
    let parent = try Self.tempDir()
    defer { try? FileManager.default.removeItem(at: parent) }
    let file = parent.appendingPathComponent("a-file.txt")
    try Data("hello".utf8).write(to: file)

    let (service, launcher) = Self.makeService(installed: ["finder"])

    do {
      _ = try await service.open(directory: file, preferred: nil)
      Issue.record("Expected .notADirectory for a regular file")
    } catch let error as EditorError {
      guard case .notADirectory = error else {
        Issue.record("Expected .notADirectory, got \(error)")
        return
      }
    } catch {
      Issue.record("Expected EditorError.notADirectory, got \(error)")
    }

    #expect(launcher.openCalls.isEmpty, "Launcher must not be invoked on a regular file")
  }

  // MARK: - Success return shape

  @Test
  func openReturnsEditorChoiceMatchingResolvedDescriptor() async throws {
    let dir = try Self.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (service, _) = Self.makeService(installed: ["cursor", "finder"])

    let choice = try await service.open(directory: dir, preferred: "cursor")
    #expect(choice.id == "cursor")
    #expect(choice.displayName == "Cursor")
    #expect(choice.binaryPath == nil, "NSWorkspace launches expose no binaryPath")
  }
}
