import SwiftUI
import TouchCodeCore

/// Per-kind agent logo shared between `ActiveAgentsRowView` (16pt) and
/// `ActiveAgentsBadgeView` (14pt). Centralises the symbol choice so a
/// future swap stays in one file.
///
/// Brand glyphs ship as SVG imagesets in `App/Assets.xcassets/`:
/// - `.claudeCode` → `claude-code` (Anthropic Claude wordmark — preserved
///   in its brand orange via the imageset's default rendering intent).
/// - `.codex`      → `codex` (OpenAI Codex spiral — `template` rendering
///   so it picks up `foregroundStyle`).
/// - `.pi`         → `pi` (Inflection pi glyph — `template` rendering;
///   the SVG ships in a near-black fill so the template path tints it
///   to the surrounding typography colour).
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

  /// Tint applied to template-rendered glyphs. Claude Code's imageset uses
  /// original rendering (preserves Anthropic's brand orange) and therefore
  /// ignores `foregroundStyle`; the value below is harmless for that case.
  private func tint(for kind: AgentKind) -> HierarchicalShapeStyle {
    switch kind {
    case .claudeCode: return .primary  // ignored by original-rendered SVG
    case .codex, .pi: return .secondary
    }
  }
}
