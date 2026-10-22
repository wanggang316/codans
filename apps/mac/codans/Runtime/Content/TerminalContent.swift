import CodansCore
import Foundation

/// The terminal Content: one libghostty surface attached to one zmx
/// session named after the `ContentID`. The engine keeps the per-session
/// state (polling, crash ring, reclaim bookkeeping) keyed by that id; this
/// is the per-instance handle the registry owns and the chip reads.
@MainActor
final class TerminalContent: TabContent {
  let id: ContentID
  let kind: ContentKind = .terminal
  let chrome = TabChrome()
  private let engine: TerminalEngine

  init(id: ContentID, engine: TerminalEngine) {
    self.id = id
    self.engine = engine
  }

  deinit {}

  var surface: PaneSurface? {
    engine.surface(for: id)
  }

  var isLive: Bool {
    engine.hasSurface(for: id)
  }

  var currentWorkingDirectory: String? {
    engine.currentWorkingDirectory(for: id)
  }

  func create(
    snapshot: ContentSnapshot, at address: TabAddress, in worktree: Worktree,
    env: [String: String], geometry: ContentGeometry?
  ) async throws {
    let surface = try await engine.ensureSurface(
      for: snapshot, at: address, in: worktree, env: env, initialSize: geometry?.size
    )
    chrome.source = surface.info
  }

  /// A live surface view follows its slot through layout
  /// (`GhosttySurfaceView.pushGeometry`), and `ContentRuntime` hands the
  /// mounted geometry to the next `create`, so a re-attach starts at the
  /// slot size. Nothing else to resize here.
  func mount(geometry: ContentGeometry) {}

  /// The surface and its daemon stay up off-screen; the engine's idle
  /// reclaim decides when a hidden surface goes.
  func unmount() {}

  func close() {
    chrome.source = nil
    engine.closeSurface(for: id)
  }

  func suspend() {
    chrome.source = nil
    engine.suspendSurface(for: id)
  }

  func acceptFocus() {
    engine.focusSurfaceView(for: id)
  }
}

extension SurfaceInfo: TabChromeSource {
  var chromeTitle: String? {
    let candidate = tabTitle ?? title
    guard let candidate, !candidate.isEmpty else { return nil }
    return candidate
  }

  var chromeProgress: Double? {
    guard isProgressBusy, let value = progressValue else { return nil }
    return Double(value) / 100
  }

  var chromeIsReadOnly: Bool { readonly }
}
