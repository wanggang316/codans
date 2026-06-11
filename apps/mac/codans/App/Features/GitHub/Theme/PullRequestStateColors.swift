import SwiftUI
import CodansCore

/// Semantic colour tokens for the GitHub integration. GitHub's web palette at ~80% saturation
/// so the badges cohabit with codans's muted sidebar chrome. State hues match GitHub's
/// convention (green open, gray draft, purple merged, dim closed); check hues follow the
/// conventional green / red / yellow.
///
/// Defined as computed `Color` statics (rather than asset-catalog entries) to land the M4
/// slice without touching Assets.xcassets. A later polish pass can promote these into the
/// catalog for proper Dark / HighContrast variants — the call sites will not change.
nonisolated enum PullRequestStateColor {
  static let openFill = Color(red: 0.25, green: 0.55, blue: 0.30)
  static let draftFill = Color(red: 0.45, green: 0.48, blue: 0.50)
  static let mergedFill = Color(red: 0.45, green: 0.32, blue: 0.60)
  static let closedFill = Color(red: 0.55, green: 0.22, blue: 0.22)

  static let onFillPrimary = Color.white
  static let onFillSecondary = Color.white.opacity(0.82)
}

/// Colour tokens for the check aggregate glyph on the badge and the per-row glyph in the
/// popover's check list.
nonisolated enum CheckRollupColor {
  static let passing = Color.green
  static let failing = Color.red
  static let pending = Color.yellow
  static let neutral = Color.gray
}

/// GitHub Primer foreground tokens for `+N −M` diff-stat counts. Matches
/// github.com's PR list / file tree rendering — `#1A7F37` for additions and
/// `#CF222E` for deletions — so the sidebar and titlebar counters look like
/// the same widget the user already reads on github.com.
nonisolated enum DiffStatColor {
  static let additions = Color(red: 0x1A / 255.0, green: 0x7F / 255.0, blue: 0x37 / 255.0)
  static let deletions = Color(red: 0xCF / 255.0, green: 0x22 / 255.0, blue: 0x2E / 255.0)
}

extension PullRequestState {
  /// Background fill for the badge capsule.
  nonisolated var badgeFill: Color {
    switch self {
    case .open: return PullRequestStateColor.openFill
    case .merged: return PullRequestStateColor.mergedFill
    case .closed: return PullRequestStateColor.closedFill
    }
  }

  /// Stroke / foreground tint used by the bordered-pill badge and the row-leading git icon.
  /// Mirrors the popover pill's fill tokens (same hue at equal saturation) so the two
  /// surfaces read as one system — the sidebar row icon + `#N` pill is the same purple
  /// the popover's "MERGED" capsule uses, not the louder stock `.purple`.
  nonisolated func rowTint(isDraft: Bool) -> Color {
    if isDraft { return .secondary }
    switch self {
    case .open: return PullRequestStateColor.openFill
    case .merged: return PullRequestStateColor.mergedFill
    case .closed: return PullRequestStateColor.closedFill
    }
  }

  /// Asset-catalog name for the GitHub-style glyph shown at the row's leading edge.
  /// Draft PRs use a dedicated dashed variant; merged / closed / open each have their own.
  nonisolated func rowIconName(isDraft: Bool) -> String {
    if isDraft { return "git-pull-request-draft" }
    switch self {
    case .open: return "git-pull-request"
    case .merged: return "git-merge"
    case .closed: return "git-pull-request-closed"
    }
  }

  /// SF Symbol for the left glyph of the badge. `isDraft` is handled separately because it
  /// modifies the symbol variant without changing the enum case.
  nonisolated func badgeSymbol(isDraft: Bool) -> String {
    switch self {
    case .open: return isDraft ? "arrow.triangle.pull" : "arrow.triangle.pull"
    case .merged: return "checkmark.circle.fill"
    case .closed: return "xmark.circle.fill"
    }
  }
}
