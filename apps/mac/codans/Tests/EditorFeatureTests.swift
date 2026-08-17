import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// `EditorFeature` coverage. The custom-editor surface
/// (add/update/remove) was retired; this suite exercises the narrowed NSWorkspace-
/// backed shape: descriptor fetch on appear, global-default write-through, error-string
/// mapping, and the `resolveDefault` cascade (project override → global → Finder).
@MainActor
struct EditorFeatureTests {
  private nonisolated static let sampleDescriptor = EditorDescriptor(
    id: "vscode",
    displayName: "Visual Studio Code",
    bundleIdentifier: "com.microsoft.VSCode",
    launchMode: .directory,
    appURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
    alternateBundleIdentifiers: []
  )

  @Test
  func onAppearFetchesDescriptors() async {
    let store = TestStore(initialState: EditorFeature.State()) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient.describe = { [Self.sampleDescriptor] }
      $0.settingsWriter = SettingsWriter.testValue
      $0.settingsWriter.readSnapshot = { .default }
      $0.hierarchyClient = HierarchyClient.testValue
    }
    store.exhaustivity = .off
    await store.send(.onAppear)
    await store.receive(\.descriptorsLoaded) { state in
      state.descriptors = [Self.sampleDescriptor]
    }
  }

  @Test
  func openRequestedRoutesRemoteWorktreesThroughTheRemoteCLI() async {
    let host = RemoteHost(alias: "mini.local", username: "alice")
    let project = Project(
      name: "srv", rootPath: "/srv/app", gitRoot: "/srv/app", remoteHost: host
    )
    var catalog = Catalog()
    catalog.projects = [project]
    let remoteCall = LockIsolated<(RemoteHost, String, EditorID?)?>(nil)
    let store = TestStore(initialState: EditorFeature.State()) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      // `open` stays unimplemented — a remote worktree must never reach the
      // local file-URL path.
      $0.editorClient.openRemote = { host, path, preferred in
        remoteCall.setValue((host, path, preferred))
        return EditorChoice(id: "zed", displayName: "Zed", binaryPath: nil)
      }
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.snapshot = { catalog }
    }
    await store.send(
      .openRequested(editorID: nil, worktreePath: "/srv/app", projectID: project.id))
    await store.receive(\.openSucceeded) {
      $0.lastOpenResult = .opened(editorID: "zed", displayName: "Zed")
    }
    #expect(remoteCall.value?.0 == host)
    #expect(remoteCall.value?.1 == "/srv/app")
    #expect(remoteCall.value?.2 == nil)
  }

  @Test
  func setGlobalDefaultWritesThroughSettingsWriter() async {
    let writtenID = LockIsolated<EditorID?>(nil)
    let store = TestStore(initialState: EditorFeature.State()) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.settingsWriter.setDefaultEditorID = { id in writtenID.setValue(id) }
      $0.hierarchyClient = HierarchyClient.testValue
    }
    await store.send(.setGlobalDefault("zed")) {
      $0.globalDefault = "zed"
    }
    await store.finish()
    #expect(writtenID.value == "zed")
  }

  @Test
  func editorErrorDescriptionMapsEveryCase() {
    #expect(
      EditorFeature.editorErrorDescription(
        .notInstalled(id: "vscode", bundleID: "com.microsoft.VSCode"))
        == "vscode is not installed")
    #expect(
      EditorFeature.editorErrorDescription(.launchFailed(reason: "Gatekeeper blocked"))
        == "Could not launch editor: Gatekeeper blocked")
    #expect(
      EditorFeature.editorErrorDescription(.notADirectory(path: "/x"))
        == "Not a directory: /x")
  }

  @Test
  func resolveDefaultPrefersProjectOverride() {
    let resolved = EditorFeature.resolveDefault(
      projectOverride: "vscode",
      globalDefault: "zed",
      descriptors: [Self.sampleDescriptor]
    )
    #expect(resolved == .editor(Self.sampleDescriptor))
  }

  @Test
  func resolveDefaultWalksPriorityWhenNoOverrideOrGlobal() {
    // When no override or global default is set, the chip must reflect what
    // the primary tap will actually open — i.e. the first installed editor
    // in `EditorRegistry.defaultPriority`. Returning `.finder` here would
    // mismatch the service-side cascade and surface the wrong default.
    let resolved = EditorFeature.resolveDefault(
      projectOverride: nil,
      globalDefault: nil,
      descriptors: [Self.sampleDescriptor]
    )
    #expect(resolved == .editor(Self.sampleDescriptor))
  }

  @Test
  func resolveDefaultFallsBackToFinderWhenNoDescriptors() {
    // The bare `.finder` sentinel is reachable only when nothing is installed
    // (defensive — `describe()` always includes at least the shell pseudo-editor).
    let resolved = EditorFeature.resolveDefault(
      projectOverride: nil,
      globalDefault: nil,
      descriptors: []
    )
    #expect(resolved == .finder)
  }

  // MARK: - resolveInstalledPreference (Codex P2-3)

  @Test
  func resolveInstalledPreferencePrefersProjectOverrideWhenInstalled() {
    let preferred = EditorFeature.resolveInstalledPreference(
      projectOverride: "vscode",
      globalDefault: "zed",
      descriptors: [Self.sampleDescriptor]
    )
    #expect(preferred == "vscode")
  }

  @Test
  func resolveInstalledPreferenceFallsToGlobalWhenOverrideUninstalled() {
    let preferred = EditorFeature.resolveInstalledPreference(
      projectOverride: "zed",  // not in descriptors
      globalDefault: "vscode",
      descriptors: [Self.sampleDescriptor]
    )
    #expect(preferred == "vscode")
  }

  @Test
  func resolveInstalledPreferenceReturnsNilWhenNothingMatches() {
    // Critical behavior: when no override or global default resolves to an installed
    // editor, return nil so the service's priority cascade can pick the first installed
    // editor (not force-land on Finder, which would short-circuit the walk).
    let preferred = EditorFeature.resolveInstalledPreference(
      projectOverride: nil,
      globalDefault: nil,
      descriptors: [Self.sampleDescriptor]
    )
    #expect(preferred == nil)
  }

  @Test
  func resolveInstalledPreferenceReturnsNilWhenOnlyStaleIDsMatch() {
    // Both override and global reference uninstalled editors — should still fall through
    // to nil rather than eagerly handing a dead ID to the service.
    let preferred = EditorFeature.resolveInstalledPreference(
      projectOverride: "cursor",
      globalDefault: "zed",
      descriptors: [Self.sampleDescriptor]
    )
    #expect(preferred == nil)
  }
}
