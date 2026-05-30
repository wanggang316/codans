import SwiftUI
import TouchCodeCore

/// Compact trailing-slot badge for a sidebar Worktree row. Renders only when the Worktree
/// has a matched PR — consumers are responsible for not mounting the view when the
/// snapshot is nil.
///
/// Three render states surfaced via `BadgeState`:
///   - `.loaded(snapshot, rollup)` — full render
///   - `.loading` — skeleton outline + progress indicator, suppressed for the first 200 ms
///     so fast responses don't flicker in (consumer-managed)
///   - `.error(GitHubError)` — tertiary-label exclamation with tooltip
///
/// `onTap` runs the badge's primary action. Hover-triggered behavior (such as opening the
/// PR popover after a 150 ms dwell) lives at the call site — this view intentionally does
/// not manage its own timers so a parent can coordinate hover across badge + popover.
struct PullRequestBadge: View {
  enum BadgeState: Equatable {
    case loaded(PullRequestSnapshot, rollup: CheckRollup)
    case loading
    case error(GitHubError)
  }

  enum CheckRollup: Equatable {
    case allPassing
    case anyFailing
    case anyPending
    case noChecks
  }

  let state: BadgeState
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      content
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
    .help(tooltip)
  }

  @ViewBuilder
  private var content: some View {
    switch state {
    case .loaded(let snapshot, let rollup):
      loadedBody(snapshot: snapshot, rollup: rollup)
    case .loading:
      loadingBody
    case .error:
      errorBody
    }
  }

  private func loadedBody(snapshot: PullRequestSnapshot, rollup: CheckRollup) -> some View {
    // Shared with the titlebar via `PullRequestNumberPill` so the `#N` chip — and its
    // red merge-conflict styling — stays identical across the sidebar and the status bar.
    PullRequestNumberPill(snapshot: snapshot)
  }

  private var loadingBody: some View {
    HStack(spacing: 3) {
      ProgressView()
        .controlSize(.mini)
      Text("loading")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 1)
    .background(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .stroke(Color.secondary.opacity(0.4), lineWidth: 0.75)
    )
  }

  private var errorBody: some View {
    Image(systemName: "exclamationmark.circle")
      .foregroundStyle(.tertiary)
      .imageScale(.small)
      .accessibilityHidden(true)
  }

  private var accessibilityLabel: Text {
    switch state {
    case .loaded(let snapshot, let rollup):
      let stateWord: String = {
        if snapshot.isDraft { return "draft" }
        switch snapshot.state {
        case .open: return "open"
        case .merged: return "merged"
        case .closed: return "closed"
        }
      }()
      let rollupWord: String = {
        switch rollup {
        case .allPassing: return "checks passing"
        case .anyFailing: return "checks failing"
        case .anyPending: return "checks pending"
        case .noChecks: return "no checks"
        }
      }()
      let conflictWord = snapshot.hasMergeConflict ? ", merge conflicts" : ""
      return Text(
        "Pull request \(snapshot.number), \(stateWord), \(rollupWord)\(conflictWord). "
          + "Activate to see details."
      )
    case .loading:
      return Text("Loading pull request status")
    case .error(let error):
      return Text("GitHub error: \(error.userFacingMessage)")
    }
  }

  private var tooltip: String {
    switch state {
    case .loaded(let snapshot, _):
      let draftTag = snapshot.isDraft ? " (draft)" : ""
      let conflictLine = snapshot.hasMergeConflict ? "\n⚠︎ Has merge conflicts" : ""
      return "#\(snapshot.number)\(draftTag) \(snapshot.title)\n@\(snapshot.author)\(conflictLine)"
    case .loading:
      return "Loading pull request status…"
    case .error(let error):
      return error.userFacingMessage
    }
  }
}

/// Convenience helper so views can compute the check rollup from a raw check list.
extension PullRequestBadge.CheckRollup {
  /// Failure conclusions that should colour the badge as anyFailing rather than passing.
  /// The plain `.failure` test missed `.timedOut` / `.actionRequired` / `.cancelled` /
  /// `.stale` / `.startupFailure` — a check that ran to completion without landing on
  /// `.success`, `.skipped`, or `.neutral` is not a green check.
  private static let failingConclusions: Set<CheckConclusion> = [
    .failure, .cancelled, .timedOut, .actionRequired, .stale, .startupFailure,
  ]

  static func from(checks: [CheckResult]) -> PullRequestBadge.CheckRollup {
    guard !checks.isEmpty else { return .noChecks }
    if checks.contains(where: {
      if case .completed = $0.status, let conclusion = $0.conclusion,
        failingConclusions.contains(conclusion)
      {
        return true
      }
      return false
    }) {
      return .anyFailing
    }
    if checks.contains(where: {
      switch $0.status {
      case .inProgress, .queued, .waiting, .pending: return true
      case .completed: return false
      }
    }) {
      return .anyPending
    }
    return .allPassing
  }
}
