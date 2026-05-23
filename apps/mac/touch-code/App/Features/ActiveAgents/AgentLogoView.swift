import SwiftUI
import TouchCodeCore

/// Per-kind agent logo shared between `ActiveAgentsRowView` (16pt) and
/// `ActiveAgentsBadgeView` (14pt). Centralises the symbol choice so a
/// future swap stays in one file.
///
/// Glyph assignment (all rendered template-style to inherit the
/// surrounding `foregroundStyle`):
///
/// - `.claudeCode` → SVG asset `claude-code` (Anthropic Claude
///   wordmark; thick strokes survive small-size rasterisation).
/// - `.codex`      → SF Symbol `chevron.left.forwardslash.chevron.right`.
///   The OpenAI Codex spiral SVG has very thin internal cutouts (≈ 0.8
///   units in a 24-unit viewBox) that vanish into a featureless blob
///   when rasterised at 14-20pt. The `</>` SF Symbol carries the
///   "code-generation" semantic without that small-size hazard.
/// - `.pi`         → SVG asset `pi` (Inflection pi glyph).
///
/// The logo is always `accessibilityHidden(true)` — the surrounding
/// row / badge already carries an a11y label that encodes the kind by
/// its `DisplayName`. Letting VoiceOver also announce the symbol name
/// would double-speak the agent identity.
struct AgentLogoView: View {
  let kind: AgentKind
  /// Render size in points. Row uses 16; badge uses 14.
  let size: CGFloat

  var body: some View {
    Group {
      switch kind {
      case .claudeCode:
        Image("claude-code")
          .resizable()
          .scaledToFit()
      case .codex:
        // SF Symbol — see the type doc for why the bundled OpenAI
        // glyph was retired here.
        Image(systemName: "chevron.left.forwardslash.chevron.right")
          .resizable()
          .scaledToFit()
      case .pi:
        Image("pi")
          .resizable()
          .scaledToFit()
      }
    }
    .frame(width: size, height: size)
    .foregroundStyle(tint(for: kind))
    .accessibilityHidden(true)
  }

  /// Tint applied to template-rendered glyphs. All three imagesets use
  /// `template` rendering so the glyph picks up this colour at draw time.
  private func tint(for kind: AgentKind) -> HierarchicalShapeStyle {
    .secondary
  }
}
