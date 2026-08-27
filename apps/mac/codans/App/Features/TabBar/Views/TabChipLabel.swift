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
/// Truncates in the middle so both ends of the title remain visible — a
/// long path's filename stays readable even as it's clipped.
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
  var icon: String? = nil
  /// Tint applied to `icon` while this tab's dedicated run-script pane is
  /// executing. A run tab keeps its script glyph instead of swapping to
  /// the spinner (`tabIsDirty` skips run panes); the colour flipping on is
  /// what reads as "running". `nil` = idle, monochrome icon.
  var iconTint: Color?

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
          .font(.system(size: 10))
          .foregroundStyle(
            iconTint ?? (isActive ? TabBarColors.activeText : TabBarColors.inactiveText)
          )
          .accessibilityHidden(true)
      }
      Text(title)
        .lineLimit(1)
        .truncationMode(.middle)
        .font(.caption)
        .foregroundStyle(isActive ? TabBarColors.activeText : TabBarColors.inactiveText)
    }
  }

  /// Brand mark for an `agent:<kind>` reference, SF Symbol otherwise. The
  /// brand asset is template-rendered and boxed to the SF Symbol's optical
  /// size so both paths sit on the same baseline and inherit the same tint.
  @ViewBuilder
  private func glyph(for icon: String) -> some View {
    if let kind = TabIconRef.agentKind(from: icon) {
      Image(AgentCatalog.descriptor(for: kind).iconAssetName)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: 11, height: 11)
        .accessibilityHidden(true)
    } else {
      Image(systemName: icon)
        .accessibilityHidden(true)
    }
  }
}
