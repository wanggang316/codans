import SwiftUI

/// View-layer projection of an in-flight `PendingWorktree`. Built by
/// `WorktreeDetailView` from the sidebar feature's state and the
/// resolved Project name, so the loading view itself has no knowledge
/// of TCA — just a value type to render.
///
/// `kind` carries either the live progress (running) or the failure
/// payload (post-`pendingWorktreeFailed`). `removing` is reserved for a
/// future deletion-with-streaming flow; codans currently deletes
/// without a pending row, so the case is unused today and kept here so
/// the deletion path can land without a schema migration.
struct WorktreeLoadingInfo: Equatable {
  enum Kind: Equatable {
    case creating(Progress)
    case failed(message: String)
    case removing
  }

  /// Streaming-output snapshot for the running case. `statusCommand`
  /// is the headline operation label and reflects the CURRENT creation
  /// phase (git-add vs. setup-script) — built upstream via
  /// `operationLabel(for:setupCommand:)` so it tracks the phase instead
  /// of pinning to git. `statusLines` is the last 5-line tail. Empty
  /// `statusLines` falls back to a static subtitle so the view never
  /// collapses to just a spinner.
  struct Progress: Equatable {
    var statusCommand: String?
    var statusLines: [String]

    /// Pure phase → operation-label mapping. This is the probeable,
    /// unit-tested core of the "operation label reflects the current
    /// phase" contract (VAL-DETAIL-007): the label MUST differ between
    /// the two creation legs rather than staying pinned to git.
    ///   - `.creatingWorktree`  → the git-checkout label ("git worktree add")
    ///   - `.runningSetupScript` → the configured setup command (trimmed,
    ///     single-lined) when present, else the generic "setup script"
    ///     label — so a project with a custom `createScript` shows the
    ///     command the user actually configured.
    ///
    /// `CreationPhase` is a pure `nonisolated enum` (no TCA coupling), so
    /// this stays a value-type mapping the loading view can render and a
    /// test can pin without a rendered tree.
    nonisolated static func operationLabel(
      for phase: CreationPhase,
      setupCommand: String?
    ) -> String {
      switch phase {
      case .creatingWorktree:
        return "git worktree add"
      case .runningSetupScript:
        let trimmed =
          setupCommand?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "setup script" }
        // Collapse to the first line so a multi-line setup script renders
        // as a single-line chip; the chip already middle-truncates.
        return trimmed.split(
          whereSeparator: \.isNewline
        ).first.map(String.init) ?? "setup script"
      }
    }
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
/// streaming. While creating or removing, this view renders ONLY the
/// content body — the worktree name, optional command chip, and 5-line
/// streaming tail — centered in the pane. The branch-identity + status
/// **skeleton placeholder blocks** (`skeleton-left` / `skeleton-middle`)
/// live in the **window toolbar** during creation, rendered by
/// `WorktreeDetailView.pendingSkeletonToolbarContent` so they sit exactly
/// where the real branch label + status pill appear on completion. The
/// failure path swaps the body for a centered warning glyph + message.
///
/// This view is the detail body *only* while `activePendingWorktree != nil`
/// (resolved in `WorktreeDetailView.detailBody`). On completion the pending
/// row leaves the array, the detail body swaps to the real
/// `worktreeToolbarContent` + terminal, and this whole view — together with
/// the pending skeleton toolbar — is removed from the tree. That
/// presence-while-loading / absence-on-completion is the probeable signal
/// (VAL-DETAIL-001 / VAL-DETAIL-003).
struct WorktreeLoadingView: View {
  let info: WorktreeLoadingInfo

  /// Stable accessibility identifiers for the loading surface. These are a
  /// fixed contract that later validation keys on (VAL-DETAIL-001 /
  /// VAL-DETAIL-003) — DO NOT rename these strings:
  ///   - `loading-view container` — the loading-view root; present while a
  ///     worktree is being created, absent once the real header + terminal
  ///     take over on completion (this whole view is replaced).
  ///   - `skeleton-left`   — branch/icon-identity placeholder block. Lives in
  ///     the **window toolbar** during creation (rendered by
  ///     `WorktreeDetailView.pendingSkeletonToolbarContent`), not in this
  ///     content body — the constant is defined here because it tags the
  ///     loading surface's contract; the view that wears it sits in the
  ///     toolbar.
  ///   - `skeleton-middle` — status placeholder block. Also lives in the
  ///     window toolbar during creation (see `skeleton-left`).
  ///   - `streaming-output` — the live, head-truncated 5-line command tail
  ///     in the content body. Always present while creating (it
  ///     reserves its 5-line space and falls back to the "Creating
  ///     worktree in <repo>…" subtitle before any output streams), so
  ///     validation can probe that the streaming surface stays visible +
  ///     updating without depending on whether git has emitted a line yet
  ///     (VAL-DETAIL-002).
  ///   - `loading-failure` — the FAILED-state root, present only when a
  ///     creation has failed (`.failed` kind). It carries a readable
  ///     "Worktree creation failed" label + the error message as its value
  ///     so a VoiceOver user (and a probe) perceives the failure rather
  ///     than the silent warning glyph. Mutually exclusive with
  ///     `container`: the failed root drops the loading/skeleton id so the
  ///     state reads as a settled error, not "still loading"
  ///     (VAL-DETAIL-004).
  enum AccessibilityID {
    static let container = "loading-view container"
    static let skeletonLeft = "skeleton-left"
    static let skeletonMiddle = "skeleton-middle"
    static let streamingOutput = "streaming-output"
    static let loadingFailure = "loading-failure"
  }

  var body: some View {
    if case .failed(let message) = info.kind {
      failedView(message: message)
    } else {
      creatingView
    }
  }

  /// Layout for the `.creating` and `.removing` states.
  ///
  /// The skeleton placeholders for the branch-identity (`skeleton-left`) and
  /// status (`skeleton-middle`) regions live in the **window toolbar** now —
  /// see `WorktreeDetailView.pendingSkeletonToolbarContent`, which renders
  /// them while `activePendingWorktree != nil` so the placeholders sit exactly
  /// where the real branch label + status pill appear on completion. This
  /// content body therefore carries NO skeleton blocks: just the worktree
  /// name, the current-phase operation chip (only during `.creating`), and the
  /// 5-line streaming tail (`streaming-output`), centered in the pane below
  /// the toolbar.
  private var creatingView: some View {
    let subtitle = subtitleText()
    return VStack(spacing: 4) {
      Text(info.name)
        .font(.title3)
      if let command = currentProgress?.statusCommand {
        Text(command)
          .font(.subheadline)
          .monospaced()
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          // Surface the active phase to accessibility: the chip's TEXT is
          // the phase-driven operation label, and exposing it as the
          // element's value makes the current leg (git-add vs. setup
          // script) readable to a probe without scraping the rendered
          // glyphs (VAL-DETAIL-007).
          .accessibilityLabel("Operation")
          .accessibilityValue(command)
      }
      // Live command tail. `truncationMode(.head)` keeps the NEWEST text
      // visible when a single line overflows; `reservesSpace` holds the
      // 5-line footprint (and the `streaming-output` id) even before any
      // output streams, where `subtitle` is the fallback "Creating
      // worktree in <repo>…" copy (VAL-DETAIL-002).
      Text(subtitle)
        .font(.subheadline)
        .monospaced()
        .foregroundStyle(.tertiary)
        .lineLimit(5, reservesSpace: true)
        .truncationMode(.head)
        .contentTransition(.opacity)
        .animation(.easeInOut, value: subtitle)
        .accessibilityIdentifier(AccessibilityID.streamingOutput)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    // Tag the root while creating/removing so validation can probe
    // `loading-view container` to confirm the loading state is in-tree.
    // On completion this whole view is replaced by the real header +
    // terminal and this id disappears (VAL-DETAIL-001).
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(AccessibilityID.container)
  }

  /// Layout for the `.failed` state: centered warning glyph + message,
  /// no skeleton header bar. The failure is a settled error, not a
  /// transient loading state, so it stays vertically centered in the pane.
  ///
  /// `.accessibilityLabel`/`.accessibilityValue` on a `.contain` container
  /// is a no-op — VoiceOver never reads them. The failure announcement is
  /// installed via `.accessibilityRepresentation` instead (the same pattern
  /// established in `AgentStateRowView` for its spoken row label), so the
  /// "Worktree creation failed" label and error `message` actually reach the
  /// accessibility tree (VAL-DETAIL-004).
  private func failedView(message: String) -> some View {
    VStack(spacing: 12) {
      // Decorative warning glyph. `accessibilityHidden` because the failure
      // is announced by the root's `accessibilityRepresentation`; the glyph
      // itself carries no additional meaning beyond the visual triangle shape.
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.largeTitle)
        .symbolRenderingMode(.multicolor)
        .accessibilityHidden(true)
      VStack(spacing: 4) {
        Text(info.name)
          .font(.title3)
        Text(message)
          .font(.subheadline)
          .monospaced()
          .foregroundStyle(.tertiary)
          .lineLimit(5, reservesSpace: true)
          .truncationMode(.head)
          .contentTransition(.opacity)
          .animation(.easeInOut, value: message)
      }
    }
    .multilineTextAlignment(.center)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(AccessibilityID.loadingFailure)
    // Proxy element carrying the spoken label + error value so VoiceOver
    // reads "Worktree creation failed" + the worktree name + message. Direct
    // `.accessibilityLabel`/`.accessibilityValue` on a `.contain` container
    // are no-ops, so the representation is the only path to the a11y tree.
    // The name is included so VoiceOver identifies WHICH worktree failed.
    .accessibilityRepresentation {
      Text("Worktree creation failed")
        .accessibilityValue("\(info.name): \(message)")
    }
  }

  private var currentProgress: WorktreeLoadingInfo.Progress? {
    if case .creating(let progress) = info.kind { return progress }
    return nil
  }

  private func subtitleText() -> String {
    switch info.kind {
    case .creating(let progress):
      let tail = progress.statusLines.suffix(PendingWorktree.progressLineWindow)
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

}

#Preview("Streaming output") {
  @Previewable @State var statusLines: [String] = []
  WorktreeLoadingView(
    info: WorktreeLoadingInfo(
      name: "feature/loading-view",
      repositoryName: "codans",
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
      repositoryName: "codans",
      kind: .failed(
        message: "fatal: 'feature/oops' is already checked out at '/tmp/old-checkout'"
      )
    )
  )
  .frame(width: 600, height: 400)
}
