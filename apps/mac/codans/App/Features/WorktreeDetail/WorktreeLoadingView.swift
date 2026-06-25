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
/// streaming. While creating, a **skeleton header** (placeholder blocks
/// standing in for the real toolbar's branch-identity + status regions,
/// which aren't known yet) sits above the worktree name, optional command
/// chip, and a 5-line streaming tail. The failure path swaps the skeleton
/// for a warning glyph.
///
/// This view is the detail body *only* while `activePendingWorktree != nil`
/// (resolved in `WorktreeDetailView.detailBody`). On completion the pending
/// row leaves the array, the detail body swaps to the real
/// `worktreeToolbarContent` + terminal, and this whole view — including the
/// skeleton accessibility ids below — is removed from the tree. That
/// presence-while-loading / absence-on-completion is the probeable signal
/// (VAL-DETAIL-001 / VAL-DETAIL-003).
struct WorktreeLoadingView: View {
  let info: WorktreeLoadingInfo

  /// Reduce Motion suppresses the skeleton's decorative light-sweep so the
  /// in-progress state never depends on animation. The placeholder *blocks*
  /// and the accessibility ids below stay present either way, keeping the
  /// loading state perceivable without the sweep (VAL-DETAIL-008). Mirrors
  /// `PendingWorktreeRow` / `AgentStateRowView`'s reduce-motion gating —
  /// gated at the call site so the shared `ShimmerModifier` is untouched.
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Stable accessibility identifiers for the loading surface. These are a
  /// fixed contract that later validation keys on (VAL-DETAIL-001 /
  /// VAL-DETAIL-003) — DO NOT rename these strings:
  ///   - `loading-view container` — the loading-view root; present while a
  ///     worktree is being created, absent once the real header + terminal
  ///     take over on completion (this whole view is replaced).
  ///   - `skeleton-left`   — branch/icon-identity placeholder block.
  ///   - `skeleton-middle` — status placeholder block.
  ///   - `streaming-output` — the live, head-truncated 5-line command tail
  ///     below the skeleton header. Always present while creating (it
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
    let subtitle = subtitleText()
    VStack(spacing: 12) {
      skeletonHeader
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
    }
    .multilineTextAlignment(.center)
    // Collapse the stack to its intrinsic height before the window-filling
    // frame centers it. The indeterminate macOS `ProgressView` in
    // `skeletonHeader` (an `NSProgressIndicator`) otherwise greedily expands
    // along the free vertical axis and self-centers in the detail pane,
    // drifting away from the name/command/tail labels below it at larger pane
    // sizes. Width stays flexible so the command + tail keep truncating.
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityElement(children: .contain)
    // Tag the root by state, NOT unconditionally: while creating/removing
    // it is the `loading-view container` (skeleton + streaming surface);
    // on failure it becomes the `loading-failure` root with a readable
    // label/value so the settled error is announced to assistive tech and
    // probeable — and the loading/skeleton id is ABSENT, so a probe reads
    // "failed, not loading" rather than seeing both ids at once
    // (VAL-DETAIL-004). The warning glyph in `skeletonHeader` stays
    // `accessibilityHidden` (decorative); this root carries the meaning.
    .modifier(LoadingStateAccessibility(info: info))
  }

  /// State-keyed accessibility identity for the loading view's root.
  /// Creating/removing → the loading container id; failed → the
  /// `loading-failure` id plus a spoken "Worktree creation failed" label
  /// and the error message as the value. Split into a modifier so the
  /// `body` stays a single declarative chain and the contract is colocated
  /// with the ids it applies (VAL-DETAIL-004).
  private struct LoadingStateAccessibility: ViewModifier {
    let info: WorktreeLoadingInfo

    func body(content: Content) -> some View {
      switch info.kind {
      case .failed(let message):
        content
          .accessibilityIdentifier(AccessibilityID.loadingFailure)
          .accessibilityLabel("Worktree creation failed")
          .accessibilityValue(message)
      case .creating, .removing:
        content
          .accessibilityIdentifier(AccessibilityID.container)
      }
    }
  }

  /// Header region for the loading state. While creating/removing it renders
  /// the real detail header's geometry as skeleton placeholder blocks —
  /// `skeleton-left` (branch/icon identity) and `skeleton-middle` (status) —
  /// so the layout reads as the header that is *about* to appear, without
  /// surfacing any real branch name or status (neither is known yet). On
  /// failure it falls back to the warning glyph the previous design used.
  @ViewBuilder
  private var skeletonHeader: some View {
    switch info.kind {
    case .creating, .removing:
      HStack(spacing: 12) {
        // Left identity placeholder: a small inline spinner (the live "work
        // is happening" cue, folded in from the old large glyph) followed by
        // a branch-label-width block. Tagged `skeleton-left`.
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          skeletonBlock(width: 120, height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(AccessibilityID.skeletonLeft)

        // Middle status placeholder, sized like the header's status capsule.
        // Tagged `skeleton-middle`.
        skeletonBlock(width: 84, height: 18)
          .accessibilityElement(children: .ignore)
          .accessibilityIdentifier(AccessibilityID.skeletonMiddle)
      }
      .fixedSize()
    case .failed:
      // Decorative warning glyph. It stays `accessibilityHidden` on
      // purpose: the failure is announced by the view root's
      // `loading-failure` element (label + error value) so VoiceOver reads
      // one clear "Worktree creation failed" message instead of an
      // unlabeled triangle glyph plus the raw static text (VAL-DETAIL-004).
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.largeTitle)
        .symbolRenderingMode(.multicolor)
        .accessibilityHidden(true)
    }
  }

  /// A single rounded-rect grey placeholder block with the decorative
  /// light-sweep. Reuses the system `.secondary` grey (no new color system)
  /// so it sits flush with the app's other neutral surfaces. The sweep is
  /// gated off under Reduce Motion; the block itself stays so the skeleton
  /// keeps its structure (VAL-DETAIL-008).
  private func skeletonBlock(width: CGFloat, height: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: height / 3)
      .fill(.secondary.opacity(0.25))
      .frame(width: width, height: height)
      .shimmer(isActive: !reduceMotion)
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
  /// local so the view file doesn't pull in `CodansCore`-flavored
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
