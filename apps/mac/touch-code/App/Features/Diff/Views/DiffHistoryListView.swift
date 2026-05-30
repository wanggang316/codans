import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Right-panel History tab body. Renders the current branch's commit
/// history with infinite scroll, per-row selection, and inline error
/// + empty + loading states. Selecting a row dispatches
/// `.historyCommitTapped`; the left drawer (T14) reads
/// `presentedCommitSha` to render that commit's full diff.
///
/// Hosted by `DiffInspectorView.historyBody` (T12).
struct DiffHistoryListView: View {
  @Bindable var store: StoreOf<DiffFeature>

  // MARK: - Body

  var body: some View {
    Group {
      if let error = store.historyState.error {
        errorBlock(error)
      } else if store.historyState.commits.isEmpty {
        if store.historyState.loading {
          loadingPlaceholder
        } else {
          emptyState
        }
      } else {
        commitList
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .accessibilityIdentifier("diff_inspector.history_list")
    .task(id: store.worktreeID) {
      // Keyed on `worktreeID` so switching Worktrees re-fires the first-page
      // load: `.worktreeSelected` resets `historyState` but does NOT eagerly
      // reload (History is lazy), and a plain `.onAppear` won't re-run while
      // this view stays mounted on the History tab — leaving the list cleared
      // but never refreshed. Idempotent on already-loaded / already-loading
      // via the reducer's `.historyAppeared` guards.
      store.send(.historyAppeared)
    }
  }

  // MARK: - States

  private var loadingPlaceholder: some View {
    ProgressView()
      .controlSize(.small)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyState: some View {
    VStack {
      Text("No commits on this branch")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("diff_inspector.history_empty_state")
  }

  private func errorBlock(_ error: GitError) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.orange)
        .font(.title3)
        .accessibilityHidden(true)
      Text(Self.errorMessage(error))
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
      Button("Retry") {
        // Atomic refresh in a single send: the reducer's
        // `.historyRefreshRequested` arm resets the cache + selection and
        // re-fires the first-page load.
        store.send(.historyRefreshRequested)
      }
      .controlSize(.small)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("diff_inspector.history_error")
  }

  // MARK: - List

  private var commitList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(store.historyState.commits.enumerated()), id: \.element.id) { index, commit in
          row(commit: commit, index: index, total: store.historyState.commits.count)
          Divider()
        }
        if store.historyState.loading {
          ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
      }
    }
  }

  @ViewBuilder
  private func row(commit: Commit, index: Int, total: Int) -> some View {
    let isSelected = store.presentedCommitSha == commit.id
    let shortSha = commit.shortID
    // Hoisted once per row render: feeds the visible metadata line and
    // the VoiceOver string so the a11y surface matches what sighted
    // users see and we don't re-invoke the formatter twice per row.
    let relativeAge = Self.relativeFormatter.localizedString(
      for: commit.date, relativeTo: Date())

    // Two-line layout mirrors the GitHub / Tower convention: subject on
    // top, `<sha> · <author> · <relative-age>` underneath in a smaller,
    // secondary-foreground font.
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(commit.subject)
          .font(.body)
          .lineLimit(1)
          .truncationMode(.tail)
        Text("\(shortSha) · \(commit.authorName) · \(relativeAge)")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    .contentShape(.rect)
    .onTapGesture {
      store.send(.historyCommitTapped(sha: commit.id))
    }
    .accessibilityIdentifier("diff_inspector.history_row.\(shortSha)")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Commit \(shortSha), \(commit.subject), \(relativeAge)")
    .accessibilityAddTraits(.isButton)
    .onAppear {
      // Infinite scroll: when the 5th-from-end row becomes visible, kick
      // the next-page load. The reducer guards on hasMore / loading /
      // error so re-entry is safe.
      if index >= total - 5 {
        store.send(.historyLoadNextPageRequested)
      }
    }
  }

  // MARK: - Helpers

  /// Shared formatter — `RelativeDateTimeFormatter` allocations are non-
  /// trivial and the list renders one row per commit. `nonisolated(unsafe)`
  /// matches the precedent set by `RecentCommitRowView`: the type is
  /// documented as thread-safe for read-only reuse. A shared helper across
  /// both views is FU material, not T13 scope.
  private nonisolated(unsafe) static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter
  }()

  /// Map a `GitError` to a single-line user-facing message. Mirrors
  /// `DiffInspectorView.errorMessage(_:)` — duplication is intentional;
  /// each view owns its surface. A shared helper across both is FU material.
  private static func errorMessage(_ error: GitError) -> String {
    switch error {
    case .notARepo: return "Not a git repository"
    case .gitMissing: return "git not found"
    case .outputTooLarge: return "Output too large"
    case .diffTooLarge: return "Diff too large"
    case .timedOut: return "git timed out"
    case .exec(_, let stderr):
      let first = stderr.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
      let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "git failed" : trimmed
    case .invalidInput(let detail): return detail
    case .unparsable: return "Unrecognised git output"
    case .malformedRemoteURL: return "Malformed remote URL"
    }
  }
}

#Preview("populated") {
  DiffHistoryListView(
    store: Store(
      initialState: {
        var state = DiffFeature.State()
        state.selectedTab = .history
        state.historyState.commits = (0..<8).map { index in
          Commit(
            id: String(repeating: String(index), count: 40),
            authorName: "Gump",
            authorEmail: "g@example.com",
            date: Date().addingTimeInterval(TimeInterval(-3600 * (index + 1))),
            subject: "Sample commit #\(index)",
            parents: []
          )
        }
        state.historyState.hasMore = true
        return state
      }(),
      reducer: { DiffFeature() }
    )
  )
  .frame(width: 280, height: 360)
}

#Preview("empty") {
  DiffHistoryListView(
    store: Store(
      initialState: {
        var state = DiffFeature.State()
        state.selectedTab = .history
        state.historyState.commits = []
        state.historyState.loading = false
        return state
      }(),
      reducer: { DiffFeature() }
    )
  )
  .frame(width: 280, height: 360)
}

#Preview("loading") {
  DiffHistoryListView(
    store: Store(
      initialState: {
        var state = DiffFeature.State()
        state.selectedTab = .history
        state.historyState.loading = true
        return state
      }(),
      reducer: { DiffFeature() }
    )
  )
  .frame(width: 280, height: 360)
}

#Preview("error") {
  DiffHistoryListView(
    store: Store(
      initialState: {
        var state = DiffFeature.State()
        state.selectedTab = .history
        state.historyState.error = .exec(code: 128, stderr: "fatal: bad revision 'HEAD'\n")
        return state
      }(),
      reducer: { DiffFeature() }
    )
  )
  .frame(width: 280, height: 360)
}
