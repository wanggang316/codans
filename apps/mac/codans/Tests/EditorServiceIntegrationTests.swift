import AppKit
import Foundation
import Testing
import CodansCore

@testable import Codans

/// C8a Phase 6.5 — integration smoke test. Hits the real `NSWorkspace` via `LiveAppLauncher`
/// to verify that a freshly-built `LiveEditorService` can open a temp directory in Finder end
/// to end. Gated behind `TC_RUN_EDITOR_INTEGRATION_TESTS=1` so CI and the default local
/// `make mac-test` run stay hermetic; enable locally when sanity-checking the NSWorkspace seam.
@MainActor
struct EditorServiceIntegrationTests {
  @Test
  func realFinderOpenAgainstLiveLauncher() async throws {
    // Swift Testing has no XCTSkip equivalent — we just return early when the opt-in env var
    // is unset so CI keeps running this target without actually talking to NSWorkspace.
    guard ProcessInfo.processInfo.environment["TC_RUN_EDITOR_INTEGRATION_TESTS"] == "1" else {
      return
    }

    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EditorServiceIntegrationTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let service = LiveEditorService(
      launcher: LiveAppLauncher(),
      globalDefault: { nil }
    )

    // `preferred: "finder"` is the safest smoke: always installed on macOS, and opening a
    // temp folder in Finder is a benign side effect.
    let choice = try await service.open(directory: tempURL, preferred: "finder")
    #expect(choice.id == "finder")
    #expect(choice.displayName == "Finder")
  }
}
