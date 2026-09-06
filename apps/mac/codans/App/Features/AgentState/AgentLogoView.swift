import CodansCore
import SwiftUI

/// Agent glyph shared between `AgentStateRowView` (16pt), `AgentStateView`
/// (14pt), and the Agents settings pane.
///
/// Draws whatever the `AgentIconRef` names: an agent's bundled brand mark
/// (asset name from its `AgentDescriptor`, so adding an agent is a
/// descriptor edit plus a bundled SVG — no switch to keep in sync here) or
/// the SF Symbol a profile overrode it with.
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
  let icon: AgentIconRef
  /// Render size in points. Row uses 16; badge uses 14.
  let size: CGFloat
  /// Foreground style applied to the template-rendered glyph. Defaults
  /// to `.secondary`; the selected row passes `.primary` so its logo
  /// reads alongside the bolder title.
  var tint: HierarchicalShapeStyle = .secondary

  /// Brand-mark convenience for the agent-state surfaces, which observe a
  /// live pane's `AgentKind` and have no profile to carry an override.
  init(kind: AgentKind, size: CGFloat, tint: HierarchicalShapeStyle = .secondary) {
    self.init(icon: .brand(kind), size: size, tint: tint)
  }

  init(icon: AgentIconRef, size: CGFloat, tint: HierarchicalShapeStyle = .secondary) {
    self.icon = icon
    self.size = size
    self.tint = tint
  }

  var body: some View {
    glyph
      .frame(width: size, height: size)
      .foregroundStyle(tint)
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private var glyph: some View {
    switch icon {
    case .brand(let kind):
      Image(AgentCatalog.descriptor(for: kind).iconAssetName)
        .resizable()
        .scaledToFit()
        // The codex glyph carries less negative padding than its peers, so
        // without an inset it reads ~15% chunkier at the same outer frame.
        .padding(kind == .codex ? size * 0.15 : 0)
        .accessibilityHidden(true)
    case .symbol(let name):
      Image(systemName: name)
        .resizable()
        .scaledToFit()
        // SF Symbols carry less built-in padding than the brand SVGs; inset
        // so both read at the same weight for one `size`.
        .padding(size * 0.1)
        .accessibilityHidden(true)
    }
  }
}
