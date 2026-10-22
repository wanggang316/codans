import ComposableArchitecture
import Foundation
import CodansCore

/// TCA dependency-injection bridge over `TerminalEngine`. Features depend on
/// this struct's closures, not on the engine directly; the `liveValue` binds
/// each closure to a concrete `TerminalEngine` instance at app startup via
/// `.withDependencies`.
nonisolated struct TerminalClient: Sendable {
  var sendInput: @MainActor @Sendable (_ contentID: ContentID, _ text: String) -> Void

  /// Deliver `text` to the pane as one paste, then submit it with a real
  /// Return keypress after a short gap.
  ///
  /// Both halves matter for coding-agent panes. `sendInput` is the script
  /// path — it presses Return after every line, which is what makes a run
  /// script execute in a shell — so a multi-line prompt sent through it would
  /// arrive as several submissions. Here the body goes through the paste
  /// path whole and lands in an agent's composer with its line breaks
  /// intact. The gap is load-bearing too: a Return that reaches the agent in
  /// the same read as the text is taken as part of the paste and never
  /// submits, which is how `text + "\n"` used to leave a newline sitting in
  /// the composer. Anything aimed at a pane that may be running an agent
  /// must go through here.
  var sendCommand: @MainActor @Sendable (_ contentID: ContentID, _ text: String) -> Void
  /// Interrupt the pane's foreground process (Ctrl-C → SIGINT). Goes through
  /// the key-event path rather than `sendInput`, whose text path filters
  /// control bytes. No-op when the pane has no live surface.
  var interrupt: @MainActor @Sendable (_ contentID: ContentID) -> Void
  var setFocus: @MainActor @Sendable (_ contentID: ContentID, _ focused: Bool) -> Void
  var retryPane: @MainActor @Sendable (_ contentID: ContentID) -> Bool

  /// Create or return the existing `PaneSurface` for the Content, through
  /// `ContentRuntime`. Throws `TerminalClient.Error.contentNotFound` if the
  /// Content is not in the current catalog. The address, Worktree and
  /// Project env are resolved here so the spawn receives everything it
  /// needs. `geometry` is the slot that will show the Content, when known;
  /// see `TerminalEngine.ensureSurface`.
  ///
  /// `async throws` because bring-up spawns the zmx daemon and completes a
  /// control-socket handshake before libghostty wires the External PTY
  /// backend onto the new surface.
  var ensureSurface:
    @MainActor @Sendable (_ contentID: ContentID, _ geometry: ContentGeometry?) async throws -> Void
  /// The content host view placed the Content in a slot of `geometry`
  /// (on appear and on every slot change); see `ContentRuntime.mount`.
  var mount: @MainActor @Sendable (_ contentID: ContentID, _ geometry: ContentGeometry) -> Void
  /// The content host view left its slot.
  var unmount: @MainActor @Sendable (_ contentID: ContentID) -> Void

  /// Look up an existing `PaneSurface` registered with the engine. Returns
  /// `nil` when no surface has been created for the Content yet; callers
  /// (notably `LazyPaneHost`) should call `ensureSurface` first on a
  /// cache miss.
  var surface: @MainActor @Sendable (_ contentID: ContentID) -> PaneSurface?

  /// Event stream from the engine. Multi-consumer: each call returns a fresh
  /// subscriber registration. Lifecycle events always delivered; output
  /// events drop under per-subscriber backpressure.
  var events: @MainActor @Sendable () -> AsyncStream<TerminalEvent>

  nonisolated enum Error: LocalizedError, Equatable, Sendable {
    case contentNotFound(ContentID)

    var errorDescription: String? {
      switch self {
      case .contentNotFound:
        return "This tab no longer exists in the workspace."
      }
    }
  }

  /// Gap between the typed text and the Return that submits it. Long enough
  /// to clear a TUI's read-coalescing / paste-detection window, short enough
  /// that a user watching the pane sees one action.
  static let submitDelay: Duration = .milliseconds(150)
}

// MARK: - Live bridge

extension TerminalClient {
  /// `contents` is the registry every surface is created, mounted and
  /// unmounted through, so the strip finds a `TabChrome` for every live
  /// Content; `envProvider` resolves the Project's env vars for the spawn.
  @MainActor
  static func live(
    engine: TerminalEngine,
    contents: ContentRuntime,
    envProvider: @escaping @MainActor (ProjectID) -> [String: String] = { _ in [:] }
  ) -> TerminalClient {
    TerminalClient(
      sendInput: { contentID, text in
        engine.ghosttyRuntime?.surface(for: contentID)?.sendInput(text)
      },
      sendCommand: { contentID, text in
        guard let surface = engine.ghosttyRuntime?.surface(for: contentID) else { return }
        surface.sendText(text)
        Task { @MainActor in
          try? await Task.sleep(for: TerminalClient.submitDelay)
          // Re-resolve rather than capturing `surface`: the pane can be
          // closed inside the gap, and submitting into a dead surface is
          // a no-op we'd rather express as "the pane is gone".
          engine.ghosttyRuntime?.surface(for: contentID)?.sendNamedKey(.enter)
        }
      },
      interrupt: { contentID in
        engine.ghosttyRuntime?.surface(for: contentID)?.sendInterrupt()
      },
      setFocus: { contentID, focused in
        engine.ghosttyRuntime?.surface(for: contentID)?.setFocus(focused)
      },
      retryPane: { contentID in engine.retryPane(contentID) },
      ensureSurface: { contentID, geometry in
        let catalog = engine.hierarchy.catalog
        guard let address = catalog.address(forContent: contentID),
          let project = catalog.projects.first(where: { $0.id == address.projectID }),
          let worktree = project.worktrees.first(where: { $0.id == address.worktreeID }),
          let content = worktree.tab(address.tabID)?.content
        else {
          throw TerminalClient.Error.contentNotFound(contentID)
        }
        let env = HierarchyManager.injectingBuiltins(
          envProvider(address.projectID), worktreePath: worktree.path, rootPath: project.rootPath,
          workspaceRoot: project.isWorkspace ? project.rootPath : nil)
        _ = try await contents.ensure(content, in: address, worktree: worktree, env: env, geometry: geometry)
      },
      mount: { contentID, geometry in contents.mount(contentID, geometry: geometry) },
      unmount: { contentID in contents.unmount(contentID) },
      surface: { contentID in engine.ghosttyRuntime?.surface(for: contentID) },
      events: { engine.events() }
    )
  }
}

// MARK: - DependencyKey

extension TerminalClient: DependencyKey {
  static let liveValue: TerminalClient = TerminalClient(
    sendInput: { _, _ in
      fatalError("TerminalClient.liveValue not configured; wire via .withDependencies at app startup")
    },
    sendCommand: { _, _ in fatalError("TerminalClient.liveValue not configured") },
    interrupt: { _ in fatalError("TerminalClient.liveValue not configured") },
    setFocus: { _, _ in fatalError("TerminalClient.liveValue not configured") },
    retryPane: { _ in fatalError("TerminalClient.liveValue not configured") },
    ensureSurface: { _, _ in fatalError("TerminalClient.liveValue not configured") },
    mount: { _, _ in fatalError("TerminalClient.liveValue not configured") },
    unmount: { _ in fatalError("TerminalClient.liveValue not configured") },
    surface: { _ in nil },
    events: { AsyncStream { $0.finish() } }
  )

  static let testValue: TerminalClient = TerminalClient(
    sendInput: unimplemented("TerminalClient.sendInput"),
    sendCommand: unimplemented("TerminalClient.sendCommand"),
    interrupt: unimplemented("TerminalClient.interrupt"),
    setFocus: unimplemented("TerminalClient.setFocus"),
    retryPane: unimplemented("TerminalClient.retryPane", placeholder: false),
    ensureSurface: unimplemented("TerminalClient.ensureSurface"),
    mount: unimplemented("TerminalClient.mount"),
    unmount: unimplemented("TerminalClient.unmount"),
    // Quiet `{ _ in nil }` mirrors the liveValue fallback above: pane-host
    // / view-side lookups for a not-yet-attached surface are an expected
    // outcome, not a test contract worth asserting. Without this default,
    // detached SwiftUI tasks in the test host record an issue against
    // `unimplemented(...)` after their owning test scope has finished.
    surface: { _ in nil },
    events: unimplemented(
      "TerminalClient.events",
      placeholder: AsyncStream { $0.finish() }
    )
  )
}

extension DependencyValues {
  var terminalClient: TerminalClient {
    get { self[TerminalClient.self] }
    set { self[TerminalClient.self] = newValue }
  }
}
