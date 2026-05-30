import SwiftUI
import TouchCodeCore

/// Per-kind agent logo shared between `AgentStateRowView` (16pt) and
/// `AgentStateView` (14pt). Centralises the symbol choice so a
/// future swap stays in one file.
///
/// Glyph assignment (all rendered template-style to inherit the
/// surrounding `foregroundStyle`):
///
/// - `.claudeCode` → SVG asset `claude-code` (Anthropic Claude
///   wordmark; thick strokes survive small-size rasterisation).
/// - `.codex`      → SVG asset `codex` (OpenAI Codex brand glyph).
/// - `.pi`         → SVG asset `pi` (Inflection pi glyph).
/// - `.opencode`   → SVG asset `opencode` (opencode brand glyph).
/// - Other agent kinds map to one template SVG asset each.
///
/// The logo is always `accessibilityHidden(true)` — the surrounding
/// row / badge already carries an a11y label that encodes the kind by
/// its `DisplayName`. Letting VoiceOver also announce the symbol name
/// would double-speak the agent identity.
///
/// The optional `tint` override lets a host (the selected row) darken
/// the glyph from the default `.secondary` to `.primary` so the
/// selected row reads as visually heavier than its neighbours.
struct AgentLogoView: View {
  let kind: AgentKind
  /// Render size in points. Row uses 16; badge uses 14.
  let size: CGFloat
  /// Foreground style applied to the template-rendered glyph. Defaults
  /// to `.secondary`; the selected row passes `.primary` so its logo
  /// reads alongside the bolder title.
  var tint: HierarchicalShapeStyle = .secondary

  var body: some View {
    Group {
      switch kind {
      case .claudeCode:
        Image("claude-code")
          .resizable()
          .scaledToFit()
      case .codex:
        // Visually inset the codex glyph so it reads ~15% smaller than
        // the claude / pi marks at the same outer frame. The bundled
        // glyph carries less negative padding than the other two, so
        // without the inset it looks chunkier in the row.
        Image("codex")
          .resizable()
          .scaledToFit()
          .padding(size * 0.15)
      case .pi:
        Image("pi")
          .resizable()
          .scaledToFit()
      case .opencode:
        Image("opencode")
          .resizable()
          .scaledToFit()
      case .gemini:
        Image("gemini")
          .resizable()
          .scaledToFit()
      case .cursorAgent:
        Image("cursor-agent")
          .resizable()
          .scaledToFit()
      case .cline:
        Image("cline")
          .resizable()
          .scaledToFit()
      case .copilot:
        Image("github-copilot")
          .resizable()
          .scaledToFit()
      case .kimi:
        Image("kimi")
          .resizable()
          .scaledToFit()
      case .droid:
        Image("droid")
          .resizable()
          .scaledToFit()
      case .amp:
        Image("amp")
          .resizable()
          .scaledToFit()
      }
    }
    .frame(width: size, height: size)
    .foregroundStyle(tint)
    .accessibilityHidden(true)
  }
}
