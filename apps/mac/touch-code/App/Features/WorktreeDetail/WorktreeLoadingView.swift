import SwiftUI

/// View-layer projection of an in-flight `PendingWorktree`. Built by
/// `WorktreeDetailView` from the sidebar feature's state and the
/// resolved Project name, so the loading view itself has no knowledge
/// of TCA — just a value type to render.
///
/// `kind` carries either the live progress (running) or the failure
/// payload (post-`pendingWorktreeFailed`). `removing` is reserved for a
/// future deletion-with-streaming flow; touch-code currently deletes
/// without a pending row, so the case is unused today and kept here so
/// the deletion path can land without a schema migration.
struct WorktreeLoadingInfo: Equatable {
  enum Kind: Equatable {
    case creating(Progress)
    case failed(message: String)
    case removing
  }

  /// Streaming-output snapshot for the running case. `statusCommand`
  /// pins the headline operation ("git worktree add"), `statusLines` is
  /// the last 5-line tail. Empty `statusLines` falls back to a static
  /// label so the view never collapses to just a spinner.
  struct Progress: Equatable {
    var statusCommand: String?
    var statusLines: [String]
  }

  let name: String
  let repositoryName: String?
  let kind: Kind

  var actionLabel: String {
    switch kind {
    case .creating: return "Creating"
    case .removing: return "Removing"
    case .failed: return "Failed"
    }
  }

  var isFailure: Bool {
    if case .failed = kind { return true }
    return false
  }
}

/// Detail-pane loading view for a worktree whose `wt sw` is still
/// streaming. Large spinner (or warning glyph on failure), worktree
/// name, optional command chip, and a 5-line streaming tail with a
/// head-truncated middle so the latest output stays visible regardless
/// of line length.
struct WorktreeLoadingView: View {
  let info: WorktreeLoadingInfo

  var body: some View {
    let subtitle = subtitleText()
    VStack(spacing: 12) {
      headerGlyph
      VStack(spacing: 4) {
        Text(info.name)
          .font(.title3)
        if let command = currentProgress?.statusCommand {
          Text(command)
            .font(.subheadline)
            .monospaced()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Text(subtitle)
          .font(.subheadline)
          .monospaced()
          .foregroundStyle(.tertiary)
          .lineLimit(5, reservesSpace: true)
          .truncationMode(.head)
          .contentTransition(.opacity)
          .animation(.easeInOut, value: subtitle)
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private var headerGlyph: some View {
    switch info.kind {
    case .creating, .removing:
      ProgressView().controlSize(.large)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.largeTitle)
        .symbolRenderingMode(.multicolor)
        .accessibilityHidden(true)
    }
  }

  private var currentProgress: WorktreeLoadingInfo.Progress? {
    if case .creating(let progress) = info.kind { return progress }
    return nil
  }

  private func subtitleText() -> String {
    switch info.kind {
    case .creating(let progress):
      let tail = progress.statusLines.suffix(PendingProgressWindow.size)
      if !tail.isEmpty { return tail.joined(separator: "\n") }
      return defaultSubtitle()
    case .removing:
      return defaultSubtitle()
    case .failed(let message):
      return message
    }
  }

  private func defaultSubtitle() -> String {
    let noun = "worktree"
    if let repositoryName = info.repositoryName {
      return "\(info.actionLabel) \(noun) in \(repositoryName)"
    }
    return "\(info.actionLabel) \(noun)…"
  }

  /// Compile-time mirror of `PendingWorktree.progressLineWindow`. Kept
  /// local so the view file doesn't pull in `TouchCodeCore`-flavored
  /// dependencies just for one Int.
  private enum PendingProgressWindow {
    static let size = 5
  }
}

#Preview("Streaming output") {
  @Previewable @State var statusLines: [String] = []
  WorktreeLoadingView(
    info: WorktreeLoadingInfo(
      name: "feature/loading-view",
      repositoryName: "touch-code",
      kind: .creating(
        WorktreeLoadingInfo.Progress(
          statusCommand: "git worktree add",
          statusLines: statusLines
        )
      )
    )
  )
  .frame(width: 600, height: 400)
  .task {
    let pool = [
      "Preparing worktree (new branch 'feature/loading-view')",
      "Enumerating objects: 1248, done.",
      "Counting objects: 100% (1248/1248), done.",
      "Compressing objects: 100% (512/512), done.",
      "Writing objects: 100% (1248/1248), 3.21 MiB | 5.40 MiB/s, done.",
      "Resolving deltas: 100% (842/842), done.",
      "HEAD is now at c4e9be3 bump v0.8.1",
    ]
    let clock = ContinuousClock()
    for line in pool {
      try? await clock.sleep(for: .milliseconds(600))
      statusLines.append(line)
    }
  }
}

#Preview("Failure") {
  WorktreeLoadingView(
    info: WorktreeLoadingInfo(
      name: "feature/oops",
      repositoryName: "touch-code",
      kind: .failed(
        message: "fatal: 'feature/oops' is already checked out at '/tmp/old-checkout'"
      )
    )
  )
  .frame(width: 600, height: 400)
}
