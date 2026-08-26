import SwiftUI
import CodansCore

/// Per-kind agent logo shared between `AgentStateRowView` (16pt),
/// `AgentStateView` (14pt), and the Agents settings pane. The asset name
/// comes from the agent's `AgentDescriptor`, so adding an agent is a
/// descriptor edit plus a bundled SVG — no switch to keep in sync here.
///
/// Every glyph is rendered template-style so it inherits the surrounding
/// `foregroundStyle`.
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
    Image(AgentCatalog.descriptor(for: kind).iconAssetName)
      .resizable()
      .scaledToFit()
      // The codex glyph carries less negative padding than its peers, so
      // without an inset it reads ~15% chunkier at the same outer frame.
      .padding(kind == .codex ? size * 0.15 : 0)
      .frame(width: size, height: size)
      .foregroundStyle(tint)
      .accessibilityHidden(true)
  }
}
