import SwiftUI

/// Full-window placeholder shown while `AppState.bringUp()` is still
/// constructing the TCA store / TerminalEngine / IPC stack. Ported from
/// supacode's `DetailPlaceholderView`: a primary spinner sitting above a
/// rotating one-liner that shimmers between transitions, so the gap
/// between the window appearing and the catalog landing reads as
/// purposeful instead of "the app is frozen". Identical visual idiom
/// across the two products keeps the launch beat coherent for users
/// running both side-by-side.
struct AppBootstrapView: View {
  @State private var messageIndex = Int.random(in: 0..<Self.messages.count)

  /// Curated launch-time messages. Mostly drop-in from supacode (so the
  /// two apps feel like siblings on launch); a couple are touch-code
  /// specific. Pure flavor — no localization, no telemetry hook.
  private static let messages = [
    "Starting TouchCode…",
    "Preparing your worktree…",
    "Getting your agents ready…",
    "Syncing git state…",
    "Indexing branches…",
    "Staging your workspace…",
    "Orchestrating terminals…",
    "Spinning up runners…",
    "Warming up shells…",
    "Aligning refs…",
    "Tuning buffers…",
    "Hydrating caches…",
    "Resolving merge conflicts telepathically…",
    "Teaching agents to say less…",
    "Sharpening code opinions…",
    "Making the bots decisive…",
    "Pruning Claude Code hedges…",
    "Telling Cursor to read the error message…",
    "Convincing Copilot to stop guessing…",
  ]

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
        .controlSize(.large)
      Text(Self.messages[messageIndex])
        .font(.title3)
        .foregroundStyle(.secondary)
        .contentTransition(.numericText())
        .shimmer(isActive: true)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .task {
      let clock = ContinuousClock()
      while !Task.isCancelled {
        try? await clock.sleep(for: .seconds(1.8))
        withAnimation(.easeInOut(duration: 0.25)) {
          var next = Int.random(in: 0..<Self.messages.count - 1)
          if next >= messageIndex { next += 1 }
          messageIndex = next
        }
      }
    }
  }
}

#Preview {
  AppBootstrapView()
    .frame(width: 800, height: 600)
}
