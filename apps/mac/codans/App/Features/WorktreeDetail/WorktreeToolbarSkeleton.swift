import SwiftUI

/// Shimmering stand-ins for the worktree window-toolbar while a creation
/// is streaming. Each view mirrors the REAL toolbar element it replaces —
/// same composition, fonts, spacings and paddings — so the creating
/// toolbar reads as the same chrome and nothing shifts when the real
/// content takes over on completion. Where the final string is already
/// known during creation (worktree/branch name, project name) the
/// placeholder bar takes that string's exact laid-out width via
/// `SkeletonTextBar` instead of a guessed constant.
///
/// Geometry sources — keep in sync when the mirrored views change:
///   - `SkeletonBranchClusterView` ← `WorktreeHeaderInfoLabel`
///   - `SkeletonStatusPillView`    ← `StatusBarView` (motivational form)
///   - `SkeletonActionChipView`    ← `HeaderRunScriptSplitButton` /
///     `HeaderOpenSplitButton`

/// Leading branch-identity placeholder. Mirrors `WorktreeHeaderInfoLabel`:
/// a 14pt leading glyph, then a two-row stack — row 1 is the branch
/// headline plus the fixed 12pt hover-affordance slot, row 2 the caption
/// context line. Both rows lay out with the real fonts and the REAL
/// strings (the pending name / project name are known during creation),
/// so the cluster's width and row positions match the settled label.
struct SkeletonBranchClusterView: View {
  /// The pending worktree's display name — becomes the branch headline
  /// (row 1) when the worktree materializes.
  let name: String
  /// Parent project display name (row 2). The common fresh-create path
  /// has worktree name == branch, which the real label collapses to just
  /// the project name — mirrored here.
  let projectName: String?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 8) {
      // The glyph a fresh worktree's identity cluster settles into
      // (`WorktreeRowIcon`'s no-PR, non-default-branch case), ghosted so
      // it reads as "loading" rather than settled chrome.
      Image("git-branch")
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 14, height: 14)
        .foregroundStyle(.secondary.opacity(0.45))
        .shimmer(isActive: !reduceMotion)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 4) {
          SkeletonTextBar(text: name, font: .headline, barHeight: 10)
          // The real label reserves a fixed 12pt trailing slot for the
          // hover chevron / switching spinner; mirror it so the cluster
          // width doesn't shrink by 12pt against the settled layout.
          Color.clear
            .frame(width: 12)
        }
        SkeletonTextBar(
          text: projectName ?? "project",
          font: .caption,
          barHeight: 7
        )
      }
    }
  }
}

/// Centered status-pill placeholder. Mirrors the footprint `StatusBarView`
/// settles into right after creation — the motivational form (a fresh
/// worktree has no PR snapshot and no toast): a `.callout`-sized glyph +
/// the footnote-monospaced hint line, padded 12pt horizontally inside the
/// toolbar's glass capsule. The stand-in string sizes the bar with the
/// real font; the live time / chord vary by a few points, which is close
/// enough for the capsule not to visibly resize on completion.
struct SkeletonStatusPillView: View {
  var body: some View {
    HStack(spacing: 8) {
      SkeletonBlock(width: 14, height: 14)
      SkeletonTextBar(
        text: "9:41 – Open Command Palette ⇧⌘P",
        font: .footnote.monospaced(),
        barHeight: 8
      )
    }
    .padding(.horizontal, 12)
  }
}

/// Ghost stand-in for one trailing split button (Run / Open). Mirrors the
/// buttons' label anatomy — 16pt icon slot, text label, system menu
/// chevron — inside the toolbar item's own glass capsule. Not actionable;
/// its job is to hold the real buttons' footprint so the trailing flexible
/// spacer resolves the same as the settled toolbar and the centered status
/// slot doesn't drift when the real buttons appear.
struct SkeletonActionChipView: View {
  /// Representative label for the button this chip stands in for. The
  /// real labels are user-configured (primary script name, default-editor
  /// name), so the stand-in only needs a typical width, not the live
  /// string.
  let labelText: String

  var body: some View {
    HStack(spacing: 6) {
      SkeletonBlock(width: 16, height: 16)
      SkeletonTextBar(text: labelText, font: .body, barHeight: 8)
      SkeletonBlock(width: 8, height: 8)
    }
    .accessibilityHidden(true)
  }
}

#Preview("Toolbar skeleton clusters") {
  VStack(alignment: .leading, spacing: 16) {
    SkeletonBranchClusterView(
      name: "feat/loading-view",
      projectName: "codans"
    )
    SkeletonStatusPillView()
    HStack(spacing: 8) {
      SkeletonActionChipView(labelText: "Run")
      SkeletonActionChipView(labelText: "Finder")
    }
  }
  .padding(24)
  .frame(width: 420)
}
