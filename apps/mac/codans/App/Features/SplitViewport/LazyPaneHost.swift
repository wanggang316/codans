import CodansCore
import ComposableArchitecture
import SwiftUI

/// Pure renderer for a single pane slot. Switches over `store.phase` to
/// show a loading placeholder, the live `PaneHostView`, or a failure with
/// retry. All `TerminalClient` calls live in the reducer — this view never
/// reads `@Dependency` directly, which was the source of the
/// `TerminalClient.liveValue not configured` fatal-error on launch with
/// a persisted catalog (reducer-scope overrides don't reach SwiftUI view
/// bodies).
///
/// The `.task` bringup trigger is NOT sent from here: it lives on the
/// owning `LeafView`, which routes it through the parent store behind a
/// membership check — a scoped store can't tell that its element was
/// removed between mount and the task body running (a transient
/// archive/delete script tab can close that fast), and a stale element
/// send trips TCA's missing-element runtime warning.
///
/// Surfaces are retained across tab switches by `TerminalEngine`'s
/// registry. The reducer's registry short-circuit reuses them on
/// reappearance; explicit teardown still goes through
/// `HierarchyClient.closePane` → `TerminalEngine.closeSurface`.
struct LazyPaneHost: View {
  @Bindable var store: StoreOf<PaneHostFeature>
  /// False until `loadingChromeDelay` has elapsed on the current
  /// `loadingPlaceholder` — see there for why the chrome waits.
  @State private var showsLoadingChrome = false
  @Environment(\.colorScheme) private var colorScheme

  /// How long a spawn runs before the placeholder admits to being one.
  /// A warm pane reaches `.ready` in ~350ms, well inside this, so the
  /// common case is a flat terminal-coloured hand-off with no chrome to
  /// blink at the user.
  private static let loadingChromeDelay: Duration = .milliseconds(600)

  var body: some View {
    content
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
          // Top-right actions menu: collapsed to a single button, expanded
          // to the actions scoped to this pane — the pane's own (hand off,
          // command queue, mute) plus everything its surface offers on
          // right-click, which is why the surface is handed in. Layered
          // above the progress strip so the card is never clipped by it.
          .overlay(alignment: .topTrailing) {
            PaneHUDView(paneID: store.paneID, surface: surface)
          }
          // Right-click menu. Attached only on `.ready` so loading / failure
          // placeholders do not get a stale menu; placed before `.animation`
          // so the animation envelope wraps the menu modifier too.
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
    case .failed(let failure):
      failurePlaceholder(failure)
    }
  }

  private var loadingPlaceholder: some View {
    // Spinner + shimmering caption for panes that are still negotiating
    // with the engine, held back by `loadingChromeDelay`. Background
    // tracks Ghostty's terminal `background` color so the hand-off to the
    // live surface is a no-op visually — switching to a fresh worktree
    // previously flashed grey (underPageBackgroundColor) for the spawn
    // window before settling onto the terminal's theme tone. The chrome
    // fades in rather than cutting in, so a spawn that crosses the delay
    // by a hair still doesn't register as a blink.
    VStack(spacing: 8) {
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
    .opacity(showsLoadingChrome ? 1 : 0)
    .animation(.easeIn(duration: 0.2), value: showsLoadingChrome)
    .modifier(terminalBackdrop)
    .task {
      try? await Task.sleep(for: Self.loadingChromeDelay)
      guard !Task.isCancelled else { return }
      showsLoadingChrome = true
    }
  }

  private func failurePlaceholder(_ failure: PaneHostFeature.Failure) -> some View {
    ContentUnavailableView {
      Label("Pane Failed to Start", systemImage: "exclamationmark.triangle")
    } description: {
      Text(failure.reason)
    } actions: {
      VStack(spacing: 12) {
        Button("Retry") {
          store.send(.retryButtonTapped)
        }
        // Raw error for bug reports; selectable so it can be copied.
        if let detail = failure.detail {
          Text(detail)
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .multilineTextAlignment(.center)
        }
      }
    }
    .modifier(terminalBackdrop)
  }

  /// Placeholders sit on the terminal's theme background so they read as
  /// part of the split (and the hand-off to a live surface doesn't flash).
  /// System text colours follow the app appearance, not the terminal theme,
  /// so the backdrop also pins the colour scheme its luminance implies —
  /// otherwise a dark theme under a light app renders dark-on-dark copy.
  private var terminalBackdrop: TerminalBackdrop {
    let background = GhosttyRuntime.shared?.backgroundColor() ?? .underPageBackgroundColor
    let perceived = background.perceivedAppearance?.bestMatch(from: [.darkAqua, .aqua])
    let scheme: ColorScheme = perceived.map { $0 == .darkAqua ? .dark : .light } ?? colorScheme
    return TerminalBackdrop(background: background, colorScheme: scheme)
  }
}

private struct TerminalBackdrop: ViewModifier {
  let background: NSColor
  let colorScheme: ColorScheme

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: background))
      .environment(\.colorScheme, colorScheme)
  }
}
