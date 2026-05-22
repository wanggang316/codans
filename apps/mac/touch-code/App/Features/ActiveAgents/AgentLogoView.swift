import SwiftUI
import TouchCodeCore

/// Per-kind agent logo shared between `ActiveAgentsRowView` (16pt) and
/// `ActiveAgentsBadgeView` (14pt). Centralises the symbol choice so a
/// future swap from SF Symbols to bundled brand glyphs (design-doc
/// OQ-2 — brand-mark licensing) only touches one file.
///
/// v1 ships SF Symbol fallbacks because the official brand marks for
/// Claude Code / Codex / pi are not freely redistributable. The
/// fallback mapping is the one pre-approved by the controller:
/// - `.claudeCode` → `sparkles`
/// - `.codex`      → `wand.and.stars`
/// - `.pi`         → `function`
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
    Image(systemName: Self.symbolName(for: kind))
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
  }

  /// SF Symbol fallback names — see type doc for the rationale.
  private static func symbolName(for kind: AgentKind) -> String {
    switch kind {
    case .claudeCode: return "sparkles"
    case .codex: return "wand.and.stars"
    case .pi: return "function"
    }
  }
}
