import SwiftUI
import TouchCodeCore

/// Leading-edge icon for a Sidebar Worktree row. Replaces the old `circle.fill`/`circle`
/// selection dot with a GitHub-style glyph that doubles as the row's PR-state signal:
///
/// - Dir-kind synthetic worktree → `folder` SF Symbol. The synthetic worktree under a
///   dir-kind Project reads as a filesystem directory rather than a git anchor.
/// - Default-branch checkout (no PR) → `star.fill` SF Symbol, tinted by `roleTint`.
///   Carries the "this is the project's default checkout" signal that previously sat
///   inline next to the worktree name. PR snapshot still wins — when a PR exists on
///   main, the row falls through to the PR-state octicon below.
/// - Worktrees with no PR snapshot (non-default) → the `git-branch` octicon tinted by
///   `roleTint` (defaults to `.secondary`). Desaturates to the selection text color
///   when the row is selected — `listRowBackground` already shows selection, so a
///   loud icon would fight the highlight.
/// - PR snapshot     → `git-pull-request`, `git-merge`, `git-pull-request-closed`, or
///   `git-pull-request-draft`, tinted by PR state (green / purple / red / grey). PR
///   state is the dominant signal when a PR exists; the role tint is suppressed.
///
/// A 10×10 circle overlays the bottom-right corner when the aggregated check rollup is
/// non-empty, so the row can surface CI health at a glance without expanding the popover.
struct WorktreeRowIcon: View {
  let snapshot: PullRequestSnapshot?
  let rollup: PullRequestBadge.CheckRollup
  let isSelected: Bool
  /// Fallback tint applied when no PR snapshot is available. Encodes the Worktree's
  /// "role" in the Project — orange for pinned rows, secondary for everything else
  /// (including the main checkout, which shares the regular-worktree palette).
  var roleTint: Color = .secondary
  /// `true` for the placeholder worktree auto-injected under a dir-kind
  /// Project (`Project.gitRoot == nil` + `worktree.path == project.rootPath`).
  /// Swaps the leading glyph to `folder` so the row reads as a filesystem
  /// directory rather than a git anchor — git semantics (branch, PR state)
  /// don't apply.
  var isSynthetic: Bool = false
  /// L3 unread override. When `true`, the row icon swaps to a bell glyph
  /// regardless of PR / branch state, and the role tint is replaced by
  /// the accent colour. PR check rollup overlay still renders unchanged.
  var hasUnreadNotification: Bool = false
  /// `true` for the project's default-branch checkout (the worktree whose
  /// path matches `Project.rootPath`, excluding the dir-kind synthetic).
  /// Swaps the leading glyph to `star.fill` so the identity marker that
  /// used to sit inline next to the name now leads the row. Suppressed
  /// when a PR snapshot is present — PR-state still wins the icon slot.
  var isDefaultBranch: Bool = false

  /// Native `List(selection:)` paints the selection chrome via NSTableView's
  /// `.sourceList` mode and sets `\.backgroundProminence = .increased` on
  /// the row content only while the selection is *emphasized* (sidebar
  /// holds first-responder, blue fill, white text). The instant focus
  /// moves to a terminal pane the fill becomes unemphasized grey, the
  /// system text color flips to dark, and `backgroundProminence` returns
  /// to `.standard`. Reading this env (rather than `\.controlActiveState`,
  /// which only tracks window-key state) keeps the icon tint in lockstep
  /// with the text color through both transitions.
  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    Group {
      if hasUnreadNotification {
        Image(systemName: "bell.fill")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 12, height: 12)
          .foregroundStyle(Color.orange)
      } else if isSynthetic {
        // Dir-kind Project's synthetic worktree: render a folder rather
        // than the `circlebadge` git-anchor glyph. 12pt inside a 14pt
        // slot mirrors the `circlebadge` sizing so the label column stays
        // aligned with sibling git rows.
        Image(systemName: "folder")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 12, height: 12)
          .foregroundStyle(tint)
          .frame(width: 14, height: 14)
      } else if isDefaultBranch && snapshot == nil {
        // Default-branch identity marker in the leading slot (replaces
        // git-branch for the main checkout). PR snapshot still trumps
        // this — falls through to the `Image(assetName)` branch below
        // and renders the PR-state octicon instead.
        Image(systemName: "star.fill")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 12, height: 12)
          .foregroundStyle(tint)
          .frame(width: 14, height: 14)
      } else {
        Image(assetName)
          .renderingMode(.template)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 14, height: 14)
          .foregroundStyle(tint)
      }
    }
    .overlay(alignment: .bottomTrailing) {
      // Bell outranks the CI rollup: unread notifications are a higher-priority
      // signal than check state, so suppress the rollup overlay entirely while
      // the bell glyph is showing rather than letting a green/red disc smear
      // over it.
      if !hasUnreadNotification { rollupBadge }
    }
    .accessibilityLabel(accessibilityLabel)
  }

  private var assetName: String {
    guard let snapshot else { return "git-branch" }
    return snapshot.state.rowIconName(isDraft: snapshot.isDraft)
  }

  private var tint: Color {
    if let snapshot {
      return snapshot.state.rowTint(isDraft: snapshot.isDraft)
    }
    if isSelected {
      // Emphasized: white on blue. Unemphasized: the same dark token the
      // system uses for the row label, so icon and text move together
      // when focus shifts to a terminal pane within the same window.
      return backgroundProminence == .increased
        ? Color(nsColor: .alternateSelectedControlTextColor)
        : Color(nsColor: .unemphasizedSelectedTextColor)
    }
    return roleTint
  }

  @ViewBuilder
  private var rollupBadge: some View {
    switch rollup {
    case .allPassing:
      rollupGlyph(symbol: "checkmark.circle.fill", color: CheckRollupColor.passing)
    case .anyFailing:
      rollupGlyph(symbol: "xmark.circle.fill", color: CheckRollupColor.failing)
    case .anyPending:
      rollupGlyph(symbol: "clock.circle.fill", color: CheckRollupColor.pending)
    case .noChecks:
      EmptyView()
    }
  }

  private func rollupGlyph(symbol: String, color: Color) -> some View {
    // Three-layer stack so the disc reads as a clean cutout from the leading
    // git glyph underneath:
    //   1. git-branch / git-pr glyph (drawn by the parent body)
    //   2. windowBackground halo — a 12pt disc that "punches out" the icon
    //      strokes beneath the rollup so the green/red/yellow disc never
    //      composites its anti-aliased edge against the icon's lines.
    //   3. 10pt state-coloured disc with the windowBackground check/x/clock
    //      glyph inside (theme-aware: near-white in light, near-black in dark).
    // Bumped fontWeight on the inner glyph keeps the check/x/clock legible at
    // sidebar density even after the 11 → 10pt shrink.
    Image(systemName: symbol)
      .resizable()
      .fontWeight(.bold)
      .frame(width: 10, height: 10)
      .symbolRenderingMode(.palette)
      .foregroundStyle(Color(nsColor: .windowBackgroundColor), color)
      .background(
        Circle()
          .fill(Color(nsColor: .windowBackgroundColor))
          .frame(width: 12, height: 12)
      )
      .offset(x: 4, y: 4)
      .accessibilityHidden(true)
  }

  private var accessibilityLabel: Text {
    if isSynthetic {
      return Text(isSelected ? "Active project folder" : "Project folder")
    }
    guard let snapshot else {
      if isDefaultBranch {
        return Text(isSelected ? "Active default branch" : "Default branch")
      }
      return Text(isSelected ? "Active worktree branch" : "Worktree branch")
    }
    let stateWord: String = {
      if snapshot.isDraft { return "draft" }
      switch snapshot.state {
      case .open: return "open"
      case .merged: return "merged"
      case .closed: return "closed"
      }
    }()
    return Text("\(stateWord) pull request #\(snapshot.number)")
  }
}
