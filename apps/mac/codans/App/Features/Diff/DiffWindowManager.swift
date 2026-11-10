import AppKit
import CodansCore
import ComposableArchitecture
import SwiftUI

/// Keeps the diff window independent of the terminal layout and main-window selection.
/// Only one diff window exists: opening another worktree retargets it, so windows do not pile up.
@MainActor
final class DiffWindowManager: NSObject, NSWindowDelegate {
  static let shared = DiffWindowManager()
  static let defaultContentSize = NSSize(width: 1300, height: 700)

  private struct Session {
    let window: NSWindow
    let store: StoreOf<DiffFeature>
  }

  static let windowIdentifier = NSUserInterfaceItemIdentifier("diff")

  /// The one test for "is this the Diff window". Window routing (for example Close Tab)
  /// calls it, so it cannot drift from the identifier that `open` sets.
  static func isDiffWindow(_ window: NSWindow) -> Bool {
    window.identifier == windowIdentifier
  }

  private var session: Session?
  /// Live shortcut map source for the window's sidebar-toggle tooltip. Set once at app
  /// bring-up; nil in tests, where the tooltip shows the title only.
  var shortcutsStore: ShortcutsStore?
  private var preferences: [WorktreeID: DiffFeature.Preference] = [:]

  func open(
    projectID: ProjectID,
    worktreeID: WorktreeID,
    path: String,
    hostID: HostID? = nil,
    title: String,
    prBase: String?,
    prRepository: URL?,
    scope: GitComparisonScope? = nil
  ) {
    if let session {
      session.window.title = title
      // The feature saves the previous worktree's preference and restores the next one's.
      session.store.send(.contextChanged(projectID, worktreeID, path, hostID))
      session.store.send(.prBaseChanged(worktreeID, prBase, prRepository))
      if let scope { session.store.send(.scopeChanged(scope)) }
      present(session.window)
      return
    }

    var state = DiffFeature.State()
    state.preferences = preferences
    let store = Store(initialState: state) { DiffFeature() }
    store.send(.contextChanged(projectID, worktreeID, path, hostID))
    store.send(.prBaseChanged(worktreeID, prBase, prRepository))
    // An explicit scope (sidebar "Show Uncommitted" / "Show Outgoing") wins over the remembered one.
    if let scope { store.send(.scopeChanged(scope)) }

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = title
    window.toolbarStyle = .unified
    window.identifier = Self.windowIdentifier
    window.contentMinSize = NSSize(width: 640, height: 420)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.delegate = self
    let controller = NSHostingController(rootView: DiffPanelView(store: store, shortcutsStore: shortcutsStore))
    // The window owns its initial and restored frame, not SwiftUI's fitting size.
    controller.sizingOptions = []
    window.contentViewController = controller
    let frameName = "DiffWindow"
    if !window.setFrameUsingName(frameName) {
      window.setContentSize(Self.defaultContentSize)
      window.center()
    }
    window.setFrameAutosaveName(frameName)
    session = Session(window: window, store: store)
    store.send(.toggle)
    present(window)
  }

  func toggleSidebar(in window: NSWindow?) -> Bool {
    guard let session, session.window === window else { return false }
    _ = withAnimation { session.store.send(.toggleSidebar) }
    return true
  }

  func updatePR(worktreeID: WorktreeID, base: String?, repository: URL?) {
    session?.store.send(.prBaseChanged(worktreeID, base, repository))
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, let session, session.window === window else { return }

    let state = session.store.state
    preferences = state.preferences
    if let worktreeID = state.worktreeID {
      preferences[worktreeID] = DiffFeature.Preference(
        scope: state.scope, base: state.base, selectedFileID: state.selectedFileID,
        filePresentation: state.filePresentation, layout: state.layout)
    }
    session.store.send(.close)
    // Releasing the hosting view tears down WKWebView; only small preferences survive.
    window.contentViewController = nil
    window.contentView = nil
    window.delegate = nil
    self.session = nil
  }

  private func present(_ window: NSWindow) {
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
