import SwiftUI
import TouchCodeCore

/// Per-kind agent logo shared between `ActiveAgentsRowView` (16pt) and
/// `ActiveAgentsBadgeView` (14pt). Centralises the symbol choice so a
/// future swap stays in one file.
///
/// Brand glyphs ship as SVG imagesets in `App/Assets.xcassets/`, all
/// three under `template` rendering so they pick up the surrounding
/// `foregroundStyle` (consistent monochrome glyphs against the popover
/// row typography):
/// - `.claudeCode` → `claude-code` (Anthropic Claude wordmark).
/// - `.codex`      → `codex` (OpenAI Codex spiral).
/// - `.pi`         → `pi` (Inflection pi glyph).
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
    Image(assetName(for: kind))
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .foregroundStyle(tint(for: kind))
      .accessibilityHidden(true)
  }

  private func assetName(for kind: AgentKind) -> String {
    switch kind {
    case .claudeCode: return "claude-code"
    case .codex: return "codex"
    case .pi: return "pi"
    }
  }

  /// Tint applied to template-rendered glyphs. All three imagesets use
  /// `template` rendering so the glyph picks up this colour at draw time.
  private func tint(for kind: AgentKind) -> HierarchicalShapeStyle {
    .secondary
  }
}
