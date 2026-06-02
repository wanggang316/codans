import ComposableArchitecture
import Foundation
import SwiftUI
import Testing
import TouchCodeCore

@testable import TouchCode

/// Regression tests for the T3 main-window shortcuts
/// (`MainWindowCommands` + `RootFeature` wiring).
///
/// `Commands` structs are hard to exercise end-to-end from a unit test —
/// SwiftUI owns their body evaluation — so these tests split the contract
/// into two layers:
///
/// 1. **Structural** — `MainWindowCommands` must hold only the root store.
///    Any `@Dependency(...)` fields re-introduce the PR-#13 ⌘E crash: the
///    `Commands` struct resolves against `liveValue`, whose
///    `HierarchyClient.snapshot` is a `fatalError` stub.
///
/// 2. **Behavioural** — each shortcut's `store.send(...)` target lands in a
///    reducer branch with the expected effect. These mirror the shortcut-to-
///    action contract so a rename or action-semantics change is caught here
///    rather than in live-smoke-test territory.
@MainActor
struct MainWindowCommandsTests {
  // MARK: - Structural

  /// Guards against new `@Dependency`, `@Environment`, or other client-resolving stored
  /// properties on `MainWindowCommands`. `@Dependency` in particular resolves to
  /// `liveValue` inside a SwiftUI `Commands` struct (TCA's `withDependencies` injection
  /// does not scope here), so any client whose `liveValue` has a `fatalError` stub crashes
  /// on first button tap. The allowed fields are inert: a closure to the root store, a
  /// resolved-shortcut snapshot, and the focus observer used to gate the destructive
  /// worktree chords. None of them carry a fatalError client.
  @Test
  func mainWindowCommandsHasNoDependencyFields() {
    let store = Store(initialState: RootFeature.State()) { RootFeature() }
    let commands = MainWindowCommands(
      store: { store },
      shortcuts: [:],
      sidebarFocus: SidebarFocusObserver()
    )
    let mirror = Mirror(reflecting: commands)
    let labels = mirror.children.compactMap(\.label)
    #expect(mirror.children.count == 3)
    #expect(Set(labels) == ["store", "shortcuts", "sidebarFocus"])
  }

  // MARK: - ⌘O (Open in Default Editor)

  @Test
  func commandODispatchesOpenDefaultForCurrentWorktreeAndForwardsToEditor() async {
    // Mirrors the ⌘O button body: `store.send(.openDefaultForCurrentWorktreeRequested)`.
    // The reducer resolves the Worktree path from selection + the catalog
    // snapshot and forwards to `EditorFeature.Action.openDefaultInCurrentWorktreeRequested`.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let worktree = Worktree(id: worktreeID, name: "w", path: "/repo")
    let project = Project(
      id: projectID, name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree]
    )
    let catalog = Catalog(projects: [project])

    var initial = RootFeature.State()
    initial.selection = HierarchySelection(
      projectID: projectID, worktreeID: worktreeID
    )

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.editorClient = EditorClient.testValue
      // Downstream resolveDefault → .openRequested → editorClient.open fires
      // a chain this test does not care about. Stub `open` to a harmless
      // Finder-like result so the unimplemented testValue doesn't record an
      // issue. The assertion below only proves the root-to-editor hop.
      $0.editorClient.open = { _, id in
        EditorChoice(
          id: id ?? EditorFeature.finderEditorID,
          displayName: "x",
          binaryPath: nil
        )
      }
      // EditorFeature.openDefaultInCurrentWorktreeRequested consults
      // SettingsWriter for the per-Project editor override; the StatusBarFeature
      // auto-clear timer subsequently consumes the continuous clock. Stub both
      // with quiet defaults so the non-exhaustive assertion below isn't drowned
      // out by stray `unimplemented` issues from the downstream chain.
      $0.settingsWriter.readSnapshotSync = { .default }
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.openDefaultForCurrentWorktreeRequested)
    await store.receive(
      .editor(
        .openDefaultInCurrentWorktreeRequested(
          projectID: projectID,
          worktreeID: worktreeID,
          worktreePath: "/repo"
        )))
  }

  @Test
  func commandOIsNoOpWhenNoWorktreeSelected() async {
    // The ⌘O button is `.disabled(!hasActiveWorktree)` in the view, but
    // the reducer must also be defensive: a stale selection without a
    // worktreeID short-circuits to `.none`, never reaching the snapshot
    // read. Proves the reducer guard that makes ⌘O crash-proof even if
    // the view-level `disabled` drifts.
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      // snapshot intentionally unstubbed — a selection-less dispatch must not
      // reach it. If the reducer regresses and calls through, the test fails
      // loudly on `unimplemented`.
    }
    store.exhaustivity = .off

    await store.send(.openDefaultForCurrentWorktreeRequested)
    // No receive → no .editor(...) dispatched.
    await store.finish()
  }

  // MARK: - ⌘⇧G (Git Viewer)

  @Test
  func commandShiftGIsNoOpWhenNoGitViewerConfigured() async {
    // Mirrors the ⌘⇧G button body:
    // `store.send(.diffInspectorToggledForCurrentWorktree)`. With the global
    // `defaultGitViewerID` unset (Default Git Viewer = None) the chord is a
    // no-op — the built-in overlay no longer exists, so nothing is dispatched.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let worktree = Worktree(id: worktreeID, name: "w", path: "/repo")
    let project = Project(
      id: projectID, name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree]
    )
    let catalog = Catalog(projects: [project])

    var initial = RootFeature.State()
    initial.selection = HierarchySelection(
      projectID: projectID, worktreeID: worktreeID
    )

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      // No git viewer configured — chord is a no-op.
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
    }

    await store.send(.diffInspectorToggledForCurrentWorktree)
    // No receive → no .editor(...) dispatched.
    await store.finish()
  }

}
