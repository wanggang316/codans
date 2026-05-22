import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore
import TouchCodeIPC

@testable import TouchCode

/// C8a Phase 6 — `EditorHandlers` IPC coverage. Pins the wire-level contract for the four
/// `editor.*` methods against stub `EditorClient` + `HierarchyClient` + live `SettingsStore`:
///
/// - `describe`: clears the service cache, then returns the DTO-mapped descriptor list.
/// - `open`: validates shape (→ `.notADirectory`), applies per-Project override when the caller
///   omits `preferred`, delegates to `EditorClient.open`, and maps `EditorError` →
///   `EditorIPCError`.
/// - `setGlobalDefault`: writes `settings.general.defaultEditorID` through `SettingsStore`.
/// - `setProjectDefault`: writes `Settings.projects[pid].defaultEditor` via
///   `SettingsStore.mutateProject`; guards unknown ProjectID via `HierarchyClient.kind(of:)`
///   and maps a nil kind → `.unknownProject`.
@MainActor
struct EditorHandlersTests {
  // MARK: - Fixtures

  private nonisolated static let sampleDescriptor = EditorDescriptor(
    id: "vscode",
    displayName: "Visual Studio Code",
    bundleIdentifier: "com.microsoft.VSCode",
    launchMode: .directory,
    appURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
    alternateBundleIdentifiers: []
  )

  private func makeStore() -> SettingsStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EditorHandlersTests-\(UUID().uuidString).json"
    )
    return SettingsStore(fileURL: url)
  }

  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EditorHandlersTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  // MARK: - describe

  @Test
  func describeReturnsMappedDescriptorsAndClearsCache() async {
    let clearCount = LockIsolated(0)
    var editor = EditorClient.testValue
    editor.describe = { [Self.sampleDescriptor] }
    editor.clearCache = { clearCount.withValue { $0 += 1 } }

    let handlers = EditorHandlers(
      editor: editor,
      hierarchy: HierarchyClient.testValue,
      settings: makeStore()
    )

    let response = await handlers.describe()
    #expect(clearCount.value == 1, "describe must clear the service cache before probing")
    #expect(response.descriptors.count == 1)
    let dto = response.descriptors[0]
    #expect(dto.id == "vscode")
    #expect(dto.bundleIdentifier == "com.microsoft.VSCode")
    #expect(dto.launchMode == .directory)
  }

  // MARK: - open

  @Test
  func openThrowsNotADirectoryWhenPathMissing() async {
    var editor = EditorClient.testValue
    editor.describe = { [] }
    editor.clearCache = {}

    let handlers = EditorHandlers(
      editor: editor,
      hierarchy: HierarchyClient.testValue,
      settings: makeStore()
    )

    let request = EditorOpenRequest(
      path: "/tmp/does-not-exist-\(UUID().uuidString)",
      preferred: nil
    )
    await #expect(throws: EditorIPCError.notADirectory) {
      _ = try await handlers.open(request)
    }
  }

  @Test
  func openForwardsPreferredWhenCallerSupplied() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let observedPreferred = LockIsolated<EditorID?>(nil)
    var editor = EditorClient.testValue
    editor.describe = { [Self.sampleDescriptor] }
    editor.clearCache = {}
    editor.open = { _, preferred in
      observedPreferred.withValue { $0 = preferred }
      return EditorChoice(id: "vscode", displayName: "Visual Studio Code", binaryPath: nil)
    }

    // Hierarchy client never gets consulted when caller supplies `preferred` — guard by
    // returning nil from `projectContaining` so any accidental consult is a no-op. We also
    // need `snapshot` not to crash if the override path is taken by mistake. The handler
    // uses `projectContaining` (not `isPathRegistered`) so subdirectory `tc open` still
    // resolves the parent project's override — Codex P2-4.
    var hierarchy = HierarchyClient.testValue
    hierarchy.isPathRegistered = { _ in nil }
    hierarchy.projectContaining = { _ in nil }
    hierarchy.snapshot = { Catalog() }

    let handlers = EditorHandlers(
      editor: editor,
      hierarchy: hierarchy,
      settings: makeStore()
    )

    let response = try await handlers.open(EditorOpenRequest(path: dir.path, preferred: "vscode"))
    #expect(observedPreferred.value == "vscode")
    #expect(response.choice.id == "vscode")
  }

  @Test
  func openMapsEditorErrorToIPCError() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    var editor = EditorClient.testValue
    editor.describe = { [] }
    editor.clearCache = {}
    editor.open = { _, _ in
      throw EditorError.launchFailed(reason: "Gatekeeper denied")
    }

    var hierarchy = HierarchyClient.testValue
    hierarchy.isPathRegistered = { _ in nil }
    hierarchy.projectContaining = { _ in nil }
    hierarchy.snapshot = { Catalog() }

    let handlers = EditorHandlers(
      editor: editor,
      hierarchy: hierarchy,
      settings: makeStore()
    )

    await #expect(throws: EditorIPCError.launchFailed) {
      _ = try await handlers.open(EditorOpenRequest(path: dir.path, preferred: "vscode"))
    }
  }

  // MARK: - setGlobalDefault

  @Test
  func setGlobalDefaultWritesThroughSettingsStore() {
    let store = makeStore()
    let handlers = EditorHandlers(
      editor: EditorClient.testValue,
      hierarchy: HierarchyClient.testValue,
      settings: store
    )

    _ = handlers.setGlobalDefault(EditorSetGlobalDefaultRequest(editorID: "cursor"))
    #expect(store.settings.general.defaultEditorID == "cursor")

    _ = handlers.setGlobalDefault(EditorSetGlobalDefaultRequest(editorID: nil))
    #expect(store.settings.general.defaultEditorID == nil)
  }

  // MARK: - setProjectDefault

  @Test
  func setProjectDefaultWritesToSettingsStore() throws {
    // v3 moved per-Project editor overrides from catalog.json to settings.json. The
    // handler validates the ProjectID against the catalog via `HierarchyClient.kind`
    // and then mutates `SettingsStore.projects[pid].defaultEditor`.
    var hierarchy = HierarchyClient.testValue
    let raw = UUID()
    let projectID = ProjectID(raw: raw)
    hierarchy.kind = { pid in pid == projectID ? .gitRepo : nil }

    let store = makeStore()
    let handlers = EditorHandlers(
      editor: EditorClient.testValue,
      hierarchy: hierarchy,
      settings: store
    )

    _ = try handlers.setProjectDefault(
      EditorSetProjectDefaultRequest(projectID: raw, editorID: "zed")
    )
    #expect(store.settings.projects[projectID]?.defaultEditor == "zed")
  }

  @Test
  func setProjectDefaultMapsUnknownProjectToIPCError() {
    var hierarchy = HierarchyClient.testValue
    hierarchy.kind = { _ in nil }  // every ProjectID is unknown

    let handlers = EditorHandlers(
      editor: EditorClient.testValue,
      hierarchy: hierarchy,
      settings: makeStore()
    )

    #expect(throws: EditorIPCError.unknownProject) {
      _ = try handlers.setProjectDefault(
        EditorSetProjectDefaultRequest(projectID: UUID(), editorID: "vscode")
      )
    }
  }
}
