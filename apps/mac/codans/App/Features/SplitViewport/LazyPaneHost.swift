import ComposableArchitecture
import SwiftUI
import CodansCore

/// Pure renderer for a single pane slot. Drives `PaneHostFeature` via
/// `.task { store.send(.task) }` and switches over `store.phase` to show
/// a loading placeholder, the live `PaneHostView`, or a failure with
/// retry. All `TerminalClient` calls live in the reducer — this view never
/// reads `@Dependency` directly, which was the source of the
/// `TerminalClient.liveValue not configured` fatal-error on launch with
/// a persisted catalog (reducer-scope overrides don't reach SwiftUI view
/// bodies).
///
/// Surfaces are retained across tab switches by `TerminalEngine`'s
/// registry. The reducer's registry short-circuit reuses them on
/// reappearance; explicit teardown still goes through
/// `HierarchyClient.closePane` → `TerminalEngine.closeSurface`.
struct LazyPaneHost: View {
  @Bindable var store: StoreOf<PaneHostFeature>

  var body: some View {
    content
      .task(id: store.paneID) {
        store.send(.task)
      }
  }

  @ViewBuilder
  private var content: some View {
    switch store.phase {
    case .ready:
      if let surface = store.surface?.surface {
        // No `.background(Color.black)` here. ghostty's Metal layer paints the
        // entire pane — an extra black SwiftUI background is both redundant
        // (hidden the moment ghostty renders) and actively harmful: it bleeds
        // into the sidebar material above via NavigationSplitView's z-stack
        // (sidebar material blends `withinWindow`, i.e. against detail pixels
        // underneath), producing a visible black band behind the sidebar's
        // translucent layer in light mode.
        PaneHostView(surface: surface)
          // 2pt progress strip pinned to the top edge of the surface,
          // driven by libghostty's OSC 9;4 reports (winget, some `gh`
          // / `cargo` subcommands, the Claude Code CLI during tool
          // execution, etc.). `surface.info` is `@Observable`, so the
          // overlay appears/disappears purely from the read site here.
          // Plain user-typed commands don't emit OSC 9;4 themselves —
          // covering those is the shell-integration layer's job.
          .overlay(alignment: .top) {
            PaneSurfaceProgressOverlay(surface: surface)
          }
          // Right-click menu (notifications-v1-1 M7.T1). Attached only on
          // `.ready` so loading / failure placeholders do not get a stale
          // menu; placed before `.animation` so the animation envelope
          // wraps the menu modifier too.
          .contextMenu {
            PaneContextMenu(
              paneID: store.paneID,
              tabID: store.tabID,
              worktreeID: store.worktreeID,
              projectID: store.projectID
            )
          }
          .animation(
            .easeInOut(duration: 0.2),
            value: surface.info.progressState
          )
      } else {
        // Should not happen — `phase == .ready` is set by the reducer
        // only together with a non-nil `surface`. Render the loading
        // placeholder as a defensive no-op so an unexpected state doesn't
        // show a broken surface.
        loadingPlaceholder
      }
    case .loading:
      loadingPlaceholder
    case .failed(let message):
      failurePlaceholder(message: message)
    }
  }

  private var loadingPlaceholder: some View {
    // Spinner + shimmering caption for panes that are still negotiating
    // with the engine. Background tracks Ghostty's terminal `background`
    // color so the hand-off to the live surface is a no-op visually —
    // switching to a fresh worktree previously flashed grey
    // (underPageBackgroundColor) for the spawn window before settling
    // onto the terminal's theme tone.
    let terminalBackground = GhosttyRuntime.shared?.backgroundColor() ?? .underPageBackgroundColor
    return VStack(spacing: 8) {
      Image(systemName: "apple.terminal.on.rectangle")
        .font(.title2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      ProgressView()
        .controlSize(.small)
      Text("Spinning up shell…")
        .font(.caption)
        .foregroundStyle(.secondary)
        .shimmer(isActive: true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: terminalBackground))
  }

  private func failurePlaceholder(message: String) -> some View {
    VStack(spacing: 8) {
      Text("Pane failed to start")
        .font(.headline)
        .foregroundStyle(.red)
      Text(message)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .multilineTextAlignment(.center)
      Button("Retry") {
        store.send(.retryButtonTapped)
      }
      .buttonStyle(.bordered)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .underPageBackgroundColor))
  }
}
