import AppKit
import Foundation
import Testing
import CodansCore

@testable import Codans

/// Resolution cascade coverage. Exercises `LiveEditorService.resolve(preferred:)`
/// across the four tiers:
///   1. Strict preferred (installed vs. not-installed).
///   2. Lenient global default (installed → use; not installed → fall through).
///   3. Priority auto-pick (first installed wins).
///   4. Finder fallback (always installed; ultimate terminator).
///
/// Uses `RecordingAppLauncher` in-memory; no NSWorkspace calls are made.
@MainActor
struct EditorServiceResolutionTests {
  // MARK: - Fixtures

  private static func urls(for ids: [EditorID]) -> [String: URL] {
    // Produces a stub install map by projecting registry entries' bundle IDs to synthetic
    // URLs. Skips .shellEditor (empty bundle ID) — the service treats shell-editor as
    // always-installed regardless of launcher state.
    var map: [String: URL] = [:]
    for id in ids {
      guard let row = EditorRegistry.registry.first(where: { $0.id == id }),
        !row.bundleIdentifier.isEmpty
      else { continue }
      map[row.bundleIdentifier] = URL(fileURLWithPath: "/Applications/\(row.displayName).app")
    }
    return map
  }

  private static func makeService(
    installed: [EditorID],
    globalDefault: EditorID? = nil
  ) -> LiveEditorService {
    let launcher = RecordingAppLauncher(installedApps: urls(for: installed))
    return LiveEditorService(launcher: launcher, globalDefault: { globalDefault })
  }

  // MARK: - Tier 1 — strict preferred

  @Test
  func strictPreferredInstalledReturnsIt() async throws {
    let service = Self.makeService(installed: ["vscode", "finder"])
    let resolved = try await service.resolve(preferred: "vscode")
    #expect(resolved.id == "vscode")
    #expect(resolved.bundleIdentifier == "com.microsoft.VSCode")
  }

  @Test
  func strictPreferredUninstalledThrowsNotInstalled() async {
    let service = Self.makeService(installed: ["finder"])  // vscode missing
    await #expect(throws: EditorError.self) {
      _ = try await service.resolve(preferred: "vscode")
    }
    // Also pin the specific case + bundleID carried on the error.
    do {
      _ = try await service.resolve(preferred: "vscode")
      Issue.record("Expected .notInstalled; resolve returned a value")
    } catch let error as EditorError {
      guard case .notInstalled(let id, let bundleID) = error else {
        Issue.record("Expected .notInstalled, got \(error)")
        return
      }
      #expect(id == "vscode")
      #expect(bundleID == "com.microsoft.VSCode")
    } catch {
      Issue.record("Expected EditorError, got \(error)")
    }
  }

  // MARK: - Tier 2 — lenient global default

  @Test
  func lenientGlobalDefaultInstalledIsUsed() async throws {
    let service = Self.makeService(installed: ["zed", "finder"], globalDefault: "zed")
    let resolved = try await service.resolve(preferred: nil)
    #expect(resolved.id == "zed")
  }

  @Test
  func lenientGlobalDefaultUninstalledFallsThroughToPriority() async throws {
    // Global default is zed, but zed isn't installed — resolver should silently fall through
    // to the priority walk instead of erroring out.
    let service = Self.makeService(
      installed: ["vscode", "finder"],
      globalDefault: "zed"
    )
    let resolved = try await service.resolve(preferred: nil)
    // Priority walk: cursor, zed, vscode, ... — vscode is the first installed hit.
    #expect(resolved.id == "vscode")
  }

  // MARK: - Tier 3 — priority auto-pick

  @Test
  func noDefaultsPriorityPicksFirstInstalled() async throws {
    // No preferred, no global default — resolver walks editorPriority + xcode + finder + ...
    // With only vscode + finder installed, the first hit is vscode.
    let service = Self.makeService(installed: ["vscode", "finder"])
    let resolved = try await service.resolve(preferred: nil)
    #expect(resolved.id == "vscode")
  }

  @Test
  func priorityOrderIsRespectedCursorBeatsVSCode() async throws {
    // Both Cursor and VSCode installed; Cursor appears earlier in editorPriority.
    let service = Self.makeService(installed: ["cursor", "vscode", "finder"])
    let resolved = try await service.resolve(preferred: nil)
    #expect(resolved.id == "cursor")
  }

  // MARK: - Tier 4 — Finder terminator

  @Test
  func onlyFinderInstalledReturnsFinder() async throws {
    let service = Self.makeService(installed: ["finder"])
    let resolved = try await service.resolve(preferred: nil)
    #expect(resolved.id == "finder")
  }

  // MARK: - Describe behaviour

  @Test
  func describeReturnsInstalledIncludingShellEditor() async {
    // `.shellEditor` is always-installed (no bundle to probe) and surfaces in every
    // editor picker so users can pick `$EDITOR` as a default. Launching through the
    // service still throws — the Pane-aware launch path (`hierarchyClient.openPane`
    // with `initialCommand: "$EDITOR"`) is the only end-to-end caller; the service is
    // retained for parity / future wiring. See `EditorService+Live.swift` open() for
    // the limitation.
    let service = Self.makeService(installed: ["vscode", "finder"])
    let descriptors = await service.describe()
    let ids = Set(descriptors.map(\.id))
    #expect(ids.contains("vscode"))
    #expect(ids.contains("finder"))
    #expect(ids.contains("editor"), ".shellEditor must surface in describe()")
    // cursor is not installed and must not appear.
    #expect(!ids.contains("cursor"))
  }
}
