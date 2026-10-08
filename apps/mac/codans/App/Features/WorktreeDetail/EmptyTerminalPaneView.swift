import SwiftUI
import CodansCore

/// Terminal-region placeholder shown when a Worktree is selected but the
/// active Tab is nil — i.e. the user closed the last Tab, or restored a
/// snapshot whose tabs were pruned. Surfaces the `.newTab` chord inline so
/// the hint stays correct even after the user rebinds it; resolves against
/// the shortcut registry and falls back to the schema default before the
/// registry has finished loading.
///
/// The "New Tab" and "Resume Session" buttons mirror the tab-bar `+` and
/// session-history accessories, so the empty page offers the same two ways
/// to get a terminal back without a trip to the tab bar.
struct EmptyTerminalPaneView: View {
  let message: String
  /// Path of the active worktree, scanned by the session-history popover.
  /// `nil` hides "Resume Session" — there is nothing to scan against.
  var worktreePath: String?
  /// SSH host of the worktree's project for Server projects, `nil` for local.
  var remoteHost: RemoteHost?
  let onNewTab: () -> Void
  let onResumeSession: (AgentSessionSummary) -> Void

  @Environment(\.resolvedShortcuts) private var resolvedShortcuts
  @State private var sessionHistoryShown = false

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "apple.terminal.on.rectangle")
        .font(.title)
        .imageScale(.large)
        .accessibilityHidden(true)
        .foregroundStyle(.secondary)
      VStack(spacing: 4) {
        Text(message)
          .font(.title3)
        hint
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      actions
        .padding(.top, 4)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var actions: some View {
    HStack(spacing: 8) {
      Button(action: onNewTab) {
        Label("New Tab", systemImage: "plus")
      }
      .helpWithShortcut("New Tab", .newTab)

      if let worktreePath {
        Button {
          sessionHistoryShown.toggle()
        } label: {
          Label("Resume Session", systemImage: "clock.arrow.circlepath")
        }
        .help("Agent Session History")
        .agentSessionHistoryPopover(
          isPresented: $sessionHistoryShown,
          worktreePath: worktreePath,
          remoteHost: remoteHost,
          onResume: onResumeSession
        )
      }
    }
    .controlSize(.large)
  }

  @ViewBuilder
  private var hint: some View {
    if let chord = newTabChord {
      Text("Press \(Text(chord).monospaced()) or click \(Text("+").bold()) to open a new terminal.")
    } else {
      Text("Click \(Text("+").bold()) to open a new terminal.")
    }
  }

  /// Resolves the `.newTab` chord from the registry, falling back to the schema default when
  /// the env-injected map is missing the entry (rare — only before `ShortcutsStore` loads).
  /// Returns `nil` only when the user has explicitly disabled the binding.
  private var newTabChord: String? {
    if let resolved = resolvedShortcuts[.newTab], resolved.isEnabled, let binding = resolved.binding {
      return ShortcutDisplay.chord(for: binding)
    }
    if let fallback = ShortcutSchema.app.entry(for: .newTab)?.defaultBinding {
      return ShortcutDisplay.chord(for: fallback)
    }
    return nil
  }
}

#Preview {
  EmptyTerminalPaneView(
    message: "No terminals open",
    worktreePath: "/tmp",
    onNewTab: {},
    onResumeSession: { _ in }
  )
  .frame(width: 600, height: 400)
}
