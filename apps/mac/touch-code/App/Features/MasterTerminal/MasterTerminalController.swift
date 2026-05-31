import AppKit
import TouchCodeCore
import os

/// Owns the single Master Terminal panel — the slide-in NSPanel that hosts
/// a `claude remote-control` session running in
/// `~/.config/touch-code/master-terminal/`. The Ghostty surface is built
/// lazily on first summon and lives for the rest of the app lifetime so
/// successive summons resume the same Claude session.
@MainActor
final class MasterTerminalController: NSObject, NSWindowDelegate {
  private(set) var isVisible: Bool = false

  /// The app the user was in when the panel was last summoned. Restored on
  /// dismiss so the user lands back where they were instead of touch-code.
  private var previousApp: NSRunningApplication?

  /// Bound at init; surface allocation requires the live libghostty
  /// `ghostty_app_t` exposed via `runtime.app`.
  private let runtime: GhosttyRuntime

  /// Lazy — the surface is not built until the user first opens the panel.
  /// Once built it survives the controller's lifetime so hide/show cycles
  /// preserve the Claude session and scrollback.
  ///
  /// Known v1 limitation: this surface is intentionally NOT registered with
  /// `GhosttyRuntime.surfacesByPaneID` (Master Terminal stays outside the
  /// Catalog). One side effect is that `GhosttyRuntime.setColorScheme(_:)`,
  /// which iterates the registry, does not push palette changes here — the
  /// embedded Claude session keeps the scheme it had at boot until the app
  /// is relaunched. Tracked as a deferred polish item; expanding the
  /// runtime to broadcast to "ambient" surfaces is out of scope for v1.
  private var paneSurface: PaneSurface?
  /// Becomes true after we've sent `claude remote-control\n` so the input is
  /// not re-typed on every summon. If the surface fails to allocate on the
  /// first summon, this stays false and the next summon retries (both
  /// allocation and the initial command).
  private var initialCommandSent: Bool = false

  init(runtime: GhosttyRuntime) {
    self.runtime = runtime
    super.init()
  }

  /// Built lazily so a touch-code launch that never opens the Master
  /// Terminal pays no NSPanel construction cost.
  private lazy var panel: MasterTerminalWindow = {
    let panel = MasterTerminalWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: true
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .floating
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .stationary,
      .fullScreenAuxiliary,
    ]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.delegate = self

    let visualEffect = NSVisualEffectView(frame: panel.contentLayoutRect)
    visualEffect.material = .hudWindow
    visualEffect.state = .active
    visualEffect.blendingMode = .behindWindow
    visualEffect.autoresizingMask = [.width, .height]
    panel.contentView = visualEffect
    return panel
  }()

  // MARK: - Public

  func toggle() {
    if isVisible {
      animateOut()
    } else {
      animateIn()
    }
  }

  // MARK: - Surface

  /// Master-Terminal-scoped PaneID. Synthetic — the panel lives outside
  /// the Catalog, so this UUID is never persisted, looked up, or routed.
  /// Stored on the controller (not freshly minted on each bringup
  /// attempt) so a deferred async surface install reuses the same daemon
  /// the previous attempt may have already started.
  private lazy var masterPaneID: PaneID = PaneID(raw: UUID())
  /// Becomes true once the async bring-up Task has been scheduled so
  /// repeated summons before the first surface arrives don't fan out
  /// multiple `zmx serve` daemons.
  private var surfaceBringupInFlight: Bool = false

  /// Build the Ghostty surface once and embed it. Returns the surface
  /// when it is already wired; returns nil while the daemon-backed
  /// bringup is still in flight. Callers gracefully degrade — the panel
  /// still slides in, just without terminal content on the first summon.
  private func ensureSurface() -> PaneSurface? {
    if let existing = paneSurface { return existing }
    scheduleSurfaceBringup()
    return nil
  }

  private func scheduleSurfaceBringup() {
    guard !surfaceBringupInFlight else { return }
    surfaceBringupInFlight = true
    let paneID = masterPaneID
    Task { @MainActor [weak self] in
      defer { self?.surfaceBringupInFlight = false }
      guard let self else { return }
      do {
        let client = try await PaneDaemonBringup.spawnDaemonAndConnect(
          paneID: paneID,
          workingDirectory: MasterTerminalBootstrap.userDirectory.path,
          env: [:]
        )
        let surface = try PaneSurface(
          runtime: self.runtime,
          paneID: paneID,
          zmxClient: client
        )
        self.installSurface(surface)
      } catch {
        Logger.masterTerminal.error(
          "surface allocation failed: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  private func installSurface(_ surface: PaneSurface) {
    paneSurface = surface
    guard let contentView = panel.contentView else { return }
    surface.view.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(surface.view)
    NSLayoutConstraint.activate([
      surface.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      surface.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      surface.view.topAnchor.constraint(equalTo: contentView.topAnchor),
      surface.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
  }

  // MARK: - Animation

  private func animateIn() {
    let screen = screenForCursor() ?? NSScreen.main ?? NSScreen.screens.first
    guard let screen else { return }

    let visibleFrame = screen.visibleFrame
    // Top 40% of the screen, full width.
    let targetHeight = visibleFrame.height * 0.40
    let targetFrame = NSRect(
      x: visibleFrame.minX,
      y: visibleFrame.maxY - targetHeight,
      width: visibleFrame.width,
      height: targetHeight
    )
    let offscreenFrame = NSRect(
      x: targetFrame.origin.x,
      y: visibleFrame.maxY,  // Above the screen — slides DOWN into place.
      width: targetFrame.width,
      height: targetFrame.height
    )

    // Capture frontmost app so we can return focus to it on dismiss. Skip
    // self — touching the panel after summon should not flip "previousApp"
    // to touch-code.
    if let frontmost = NSWorkspace.shared.frontmostApplication,
      frontmost.bundleIdentifier != Bundle.main.bundleIdentifier
    {
      previousApp = frontmost
    }

    let surface = ensureSurface()

    panel.setFrame(offscreenFrame, display: false)
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    panel.makeKey()

    if let surface {
      // Two distinct focus calls: AppKit responder chain (so keystrokes
      // route to the surface view) and libghostty's internal focus bool
      // (so the cursor draws filled and animations advance). Both are
      // needed; neither subsumes the other.
      panel.makeFirstResponder(surface.view)
      surface.setFocus(true)
    }

    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.18
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().setFrame(targetFrame, display: true)
      panel.animator().alphaValue = 1
    }
    isVisible = true

    // Send the initial `claude remote-control` command once the surface is
    // ready. Single-shot — preserved across hide/show cycles. The 500 ms
    // delay is a heuristic giving the user's shell time to load rc files
    // and emit a prompt before we type — without it, a slow zsh / heavy
    // oh-my-zsh config can race the keystrokes and either echo them mid-
    // load or have them swallowed by pre-prompt input handling. The right
    // long-term fix is to launch via libghostty's surface `command` config
    // (bypassing the shell entirely), but `PaneSurface` does not expose
    // that field today, and the same race exists for Catalog panes via
    // `TerminalEngine.swift` — both should land together in a follow-up.
    if let surface, !initialCommandSent {
      initialCommandSent = true
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 500_000_000)
        surface.sendInput("claude remote-control\n")
      }
    }
  }

  private func animateOut() {
    guard isVisible else { return }
    isVisible = false  // Set first so windowDidResignKey re-entry is a no-op.

    paneSurface?.setFocus(false)

    var offscreenFrame = panel.frame
    if let screen = panel.screen ?? NSScreen.main {
      offscreenFrame.origin.y = screen.visibleFrame.maxY
    } else {
      offscreenFrame.origin.y += offscreenFrame.height
    }

    let appToRestore = previousApp
    previousApp = nil

    NSAnimationContext.runAnimationGroup(
      { ctx in
        ctx.duration = 0.16
        ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
        panel.animator().setFrame(offscreenFrame, display: true)
        panel.animator().alphaValue = 0
      },
      completionHandler: { [weak self] in
        guard let self else { return }
        // AppKit fires animation completion handlers on the main thread.
        MainActor.assumeIsolated {
          self.panel.orderOut(nil)
          appToRestore?.activate()
        }
      }
    )
  }

  private func screenForCursor() -> NSScreen? {
    let cursor = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(cursor) }
  }

  // MARK: - NSWindowDelegate

  func windowDidResignKey(_ notification: Notification) {
    // Click-away dismissal — matches upstream quick terminal behavior.
    guard isVisible else { return }
    animateOut()
  }
}
