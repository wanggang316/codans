import SwiftUI
import CodansCore

/// The 360 pt popover anchored to a `PullRequestBadge`. Owns four sections — header,
/// checks, actions, footer link — and swaps between loaded / loading / error / no-PR
/// bodies based on the data it was given.
///
/// The popover is a pure consumer of state: all actions are callbacks bubbled up to the
/// parent feature. That keeps the view testable in previews without a TCA store and
/// matches the C8 editor-picker pattern.
struct PullRequestPopover: View {
  enum Content: Equatable {
    case loaded(PullRequestSnapshot, checks: [CheckResult], workflowRun: WorkflowRun?)
    case loading
    case error(GitHubError)
    case noPullRequest(branch: String)
  }

  let content: Content
  let defaultMergeStrategy: MergeStrategy
  let canMerge: Bool
  let mergeDisabledReason: String?
  let onMerge: (MergeStrategy) -> Void
  let onClose: () -> Void
  let onMarkReady: () -> Void
  let onRerunFailedJobs: () -> Void
  let onOpenOnWeb: () -> Void
  let onOpenCheckLog: (URL) -> Void
  let onSetProjectDefaultStrategy: (MergeStrategy) -> Void
  let onRetry: () -> Void

  var body: some View {
    contentView
      .frame(width: 360)
      .padding(12)
      // Toolbar-anchored hosts (status bar) ship a smaller default
      // `controlSize` into the popover than List-row hosts (sidebar),
      // so the same popover otherwise rendered at two different sizes
      // depending on which surface opened it. Pinning `.regular` here
      // normalises both surfaces (HAN-60).
      .controlSize(.regular)
  }

  @ViewBuilder
  private var contentView: some View {
    switch content {
    case .loaded(let snapshot, let checks, let workflowRun):
      loadedBody(snapshot: snapshot, checks: checks, workflowRun: workflowRun)
    case .loading:
      loadingBody
    case .error(let err):
      errorBody(err)
    case .noPullRequest(let branch):
      noPullRequestBody(branch: branch)
    }
  }

  // MARK: - Loaded

  private func loadedBody(
    snapshot: PullRequestSnapshot, checks: [CheckResult], workflowRun: WorkflowRun?
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      header(snapshot: snapshot)
      if snapshot.hasMergeConflict {
        conflictBanner
      }
      if !checks.isEmpty {
        Divider()
        checksSection(checks)
      }
      Divider()
      actions(snapshot: snapshot, workflowRun: workflowRun)
    }
  }

  /// Inline merge-conflict notice. The disabled merge button's tooltip already explains
  /// *why* merge is off, but that's only discoverable on hover — surfacing the conflict
  /// as a persistent banner makes the blocker visible the moment the popover opens.
  /// Gated on `PullRequestSnapshot.hasMergeConflict` (the same predicate the sidebar /
  /// titlebar pills redden on), so all three surfaces agree on what "conflicted" means.
  private var conflictBanner: some View {
    // Wrap via `lineLimit`, exactly like the header title (which wraps reliably in this
    // popover). `fixedSize(vertical:)` does NOT work here: inside the HStack the Text is
    // sized at its single-line width first, so its "ideal height" is one line and it
    // truncates ("…resol…") instead of wrapping. `lineLimit(3)` instead tells the layout
    // the Text may reflow across up to three lines, so it wraps within the available
    // width. `.top` keeps the icon level with the first line.
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .accessibilityHidden(true)
      Text("Merge conflicts — this branch can't be merged until they're resolved.")
        .font(.caption)
        .foregroundStyle(.primary)
        .multilineTextAlignment(.leading)
        .lineLimit(3)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.red.opacity(0.12))
    )
    .accessibilityElement(children: .combine)
  }

  private func header(snapshot: PullRequestSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("#\(snapshot.number)")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
        Text(snapshot.title)
          .font(.callout.weight(.semibold))
          .lineLimit(2)
      }
      HStack(spacing: 6) {
        statePill(snapshot)
        Text("opened by @\(snapshot.author)")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("·")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("+\(snapshot.additions) −\(snapshot.deletions)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Text("·")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("\(snapshot.commitCount) commit\(snapshot.commitCount == 1 ? "" : "s")")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func statePill(_ snapshot: PullRequestSnapshot) -> some View {
    let label: String = {
      if snapshot.isDraft && snapshot.state == .open { return "Draft" }
      switch snapshot.state {
      case .open: return "Open"
      case .merged: return "Merged"
      case .closed: return "Closed"
      }
    }()
    let fill: Color = snapshot.isDraft ? PullRequestStateColor.draftFill : snapshot.state.badgeFill
    return Text(label)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(PullRequestStateColor.onFillPrimary)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule(style: .continuous).fill(fill))
  }

  private func checksSection(_ checks: [CheckResult]) -> some View {
    let (passed, failed, pending) = classify(checks)
    let sorted = sortedByFailingFirst(checks)
    let visible = Array(sorted.prefix(5))
    let hidden = sorted.count - visible.count
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Checks").font(.caption.weight(.semibold))
        Spacer()
        Text(summary(passed: passed, failed: failed, pending: pending))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      ForEach(visible, id: \.id) { check in
        CheckRow(check: check, onOpenLog: onOpenCheckLog)
      }
      if hidden > 0 {
        Text("… \(hidden) more")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
  }

  private func actions(snapshot: PullRequestSnapshot, workflowRun: WorkflowRun?) -> some View {
    HStack(spacing: 8) {
      MergeSplitButton(
        defaultStrategy: defaultMergeStrategy,
        isDisabled: !canMerge,
        disabledReason: mergeDisabledReason,
        onMerge: onMerge,
        onSetProjectDefault: onSetProjectDefaultStrategy
      )
      if snapshot.state == .open {
        Button("Close") { onClose() }
          .buttonStyle(.borderedProminent)
          .tint(Color.secondary.opacity(0.25))
          .foregroundStyle(.primary)
      }
      if snapshot.isDraft && snapshot.state == .open {
        Button("Mark ready") { onMarkReady() }
          .buttonStyle(.borderedProminent)
          .tint(Color.secondary.opacity(0.25))
          .foregroundStyle(.primary)
      }
      if let run = workflowRun, run.conclusion == .failure {
        Button("Rerun failed") { onRerunFailedJobs() }
          .buttonStyle(.borderedProminent)
          .tint(Color.secondary.opacity(0.25))
          .foregroundStyle(.primary)
      }
      Spacer()
      Button {
        onOpenOnWeb()
      } label: {
        Image(systemName: "arrow.up.right.square")
      }
      .buttonStyle(.borderless)
      .help("Open on GitHub")
    }
  }

  // MARK: - loading / error / no-PR

  private var loadingBody: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(0..<3, id: \.self) { _ in
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.secondary.opacity(0.2))
          .frame(height: 14)
      }
    }
  }

  private func errorBody(_ error: GitHubError) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)
        .font(.title2)
      Text(error.userFacingMessage)
        .font(.callout)
        .multilineTextAlignment(.center)
      retryButton(for: error)
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private func retryButton(for error: GitHubError) -> some View {
    switch error {
    case .notInstalled:
      Button("Install gh") { onRetry() }
        .buttonStyle(.borderedProminent)
    case .notAuthenticated:
      Button("Run gh auth login") { onRetry() }
        .buttonStyle(.borderedProminent)
    default:
      Button("Retry") { onRetry() }
        .buttonStyle(.bordered)
    }
  }

  private func noPullRequestBody(branch: String) -> some View {
    VStack(spacing: 8) {
      Text("No pull request for branch \(branch)")
        .font(.callout)
        .foregroundStyle(.secondary)
      Button("Create on GitHub") { onOpenOnWeb() }
        .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Helpers

  private func classify(_ checks: [CheckResult]) -> (passed: Int, failed: Int, pending: Int) {
    var passed = 0
    var failed = 0
    var pending = 0
    for c in checks {
      switch c.status {
      case .completed:
        if c.conclusion == .success { passed += 1 } else if c.conclusion == .failure { failed += 1 }
      case .inProgress, .queued, .waiting, .pending:
        pending += 1
      }
    }
    return (passed, failed, pending)
  }

  private func sortedByFailingFirst(_ checks: [CheckResult]) -> [CheckResult] {
    checks.sorted { a, b in
      rank(a) < rank(b)
    }
  }

  private func rank(_ check: CheckResult) -> Int {
    switch (check.status, check.conclusion) {
    case (.completed, .failure): return 0
    case (.inProgress, _), (.queued, _), (.waiting, _), (.pending, _): return 1
    default: return 2
    }
  }

  private func summary(passed: Int, failed: Int, pending: Int) -> String {
    var parts: [String] = []
    if passed > 0 { parts.append("\(passed) passed") }
    if failed > 0 { parts.append("\(failed) failed") }
    if pending > 0 { parts.append("\(pending) pending") }
    return parts.joined(separator: " · ")
  }
}
