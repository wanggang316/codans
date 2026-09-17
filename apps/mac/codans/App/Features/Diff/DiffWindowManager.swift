import AppKit
import CodansCore
import ComposableArchitecture
import SwiftUI

/// Keeps diff sessions independent of the terminal layout and main-window selection.
@MainActor
final class DiffWindowManager: NSObject, NSWindowDelegate {
  static let shared = DiffWindowManager()

  private struct Session {
    let window: NSWindow
    let store: StoreOf<DiffFeature>
    let toolbar: DiffWindowToolbar
  }

  private var sessions: [WorktreeID: Session] = [:]
  private var preferences: [WorktreeID: DiffFeature.Preference] = [:]

  func open(
    projectID: ProjectID,
    worktreeID: WorktreeID,
    path: String,
    title: String,
    prBase: String?,
    prRepository: URL?
  ) {
    if let session = sessions[worktreeID] {
      session.window.title = title
      session.store.send(.prBaseChanged(worktreeID, prBase, prRepository))
      present(session.window)
      return
    }

    var state = DiffFeature.State()
    if let preference = preferences[worktreeID] {
      state.preferences[worktreeID] = preference
    }
    let store = Store(initialState: state) { DiffFeature() }
    store.send(.contextChanged(projectID, worktreeID, path))
    store.send(.prBaseChanged(worktreeID, prBase, prRepository))

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = title
    window.toolbarStyle = .unifiedCompact
    let toolbar = DiffWindowToolbar(store: store)
    window.toolbar = toolbar.makeToolbar()
    window.identifier = NSUserInterfaceItemIdentifier("diff-\(worktreeID)")
    window.contentMinSize = NSSize(width: 640, height: 420)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.delegate = self
    window.contentView = NSHostingView(rootView: DiffPanelView(store: store))
    let frameName = "DiffWindow-\(worktreeID)"
    if !window.setFrameUsingName(frameName) { window.center() }
    window.setFrameAutosaveName(frameName)
    sessions[worktreeID] = Session(window: window, store: store, toolbar: toolbar)
    store.send(.toggle)
    present(window)
  }

  func updatePR(worktreeID: WorktreeID, base: String?, repository: URL?) {
    sessions[worktreeID]?.store.send(.prBaseChanged(worktreeID, base, repository))
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      let entry = sessions.first(where: { $0.value.window === window })
    else { return }

    let state = entry.value.store.state
    preferences[entry.key] = DiffFeature.Preference(
      scope: state.scope, base: state.base, selectedFileID: state.selectedFileID, layout: state.layout)
    entry.value.store.send(.close)
    // Releasing the hosting view tears down WKWebView; only small preferences survive.
    window.contentView = nil
    window.delegate = nil
    sessions.removeValue(forKey: entry.key)
  }

  private func present(_ window: NSWindow) {
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
