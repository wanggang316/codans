import CodansCore
import SwiftUI

/// The text portion of a tab chip. Kept separate from the chip container so
/// it owns its own typography + truncation discipline.
///
/// When `isDirty` is `true`, a 12×12 mini progress spinner leads the label
/// to signal that some pane inside the tab is executing a tracked command.
/// The slot collapses to zero when `isDirty` is `false` so the label sits
/// flush with the chip edge the rest of the time.
///
/// Typography follows the system tab bar: 11-pt system font truncated at
/// the tail. The selected tab keeps the regular weight (the system bar sets
/// it semibold) and is told apart by its capsule and primary text color.
struct TabChipLabel: View {
  let title: String
  var isActive: Bool = false
  var isDirty: Bool = false
  /// Unread dot. Rendered as a 4 px filled circle immediately before
  /// the title text. Boolean only — no count, no kind distinction.
  var hasUnreadNotification: Bool = false
  /// Resolved glyph from `Tab.resolvedIcon` — an SF Symbol name, or an
  /// `agent:<kind>` brand reference (see `TabIconRef`). The
  /// running-spinner and bell still claim their slots first; the icon
  /// prefixes the title only when those quieter signals are absent so the
  /// chip never tries to render three leading glyphs at once.
  var icon: String?
  /// Tint applied to `icon` while this tab's dedicated run-script pane is
  /// executing. A run tab keeps its script glyph instead of swapping to
  /// the spinner (`tabIsDirty` skips run panes); the colour flipping on is
  /// what reads as "running". `nil` = idle, monochrome icon.
  var iconTint: Color?

  @Environment(\.colorScheme) private var colorScheme

  /// An idle chip's title is the selected title dimmed, not recolored: a
  /// style change makes SwiftUI replace the text at its final frame, so in
  /// an add / close reflow the title would jump ahead of its chip, while an
  /// opacity change animates in place. Pixel-identical to the secondary
  /// label color (see `TabBarColors.inactiveTextOpacity`).
  private var textOpacity: Double {
    isActive ? 1 : TabBarColors.inactiveTextOpacity(for: colorScheme)
  }

  var body: some View {
    HStack(spacing: 4) {
      if isDirty {
        ProgressView()
          .controlSize(.mini)
          .frame(width: 12, height: 12)
      } else if hasUnreadNotification {
        Image(systemName: "bell.fill")
          .font(.system(size: 8))
          .foregroundStyle(.orange)
          .accessibilityLabel("Has unread notifications")
      } else if let icon, !icon.isEmpty {
        glyph(for: icon)
          .font(.system(size: 11))
          .foregroundStyle(iconTint ?? TabBarColors.activeText)
          .opacity(iconTint == nil ? textOpacity : 1)
          .accessibilityHidden(true)
      }
      Text(title)
        .lineLimit(1)
        .truncationMode(.tail)
        .font(.system(size: TabBarMetrics.titleFontSize))
        // A chip resizing in an add / close reflow re-truncates its title;
        // swap the truncation outright instead of cross-fading the two
        // strings, which leaves a ghost ellipsis behind the text.
        .contentTransition(.identity)
        .foregroundStyle(TabBarColors.activeText)
        .opacity(textOpacity)
    }
  }

  /// Agent brand mark, tool mark or SF Symbol. Marks are template-rendered
  /// and boxed to the SF Symbol's optical size so every path sits on the same
  /// baseline and inherits the same tint.
  private func glyph(for icon: String) -> some View {
    StoredIconGlyph(icon: icon, markSize: 11)
      .accessibilityHidden(true)
  }
}
