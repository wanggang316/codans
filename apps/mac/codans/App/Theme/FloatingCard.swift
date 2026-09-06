import SwiftUI

/// Chrome for the overlay cards hosted inside the main window — the Command
/// Palette and the Hand Off panel. Both float over the split view rather than
/// living in their own window, so nothing gives them the separation AppKit
/// grants a real panel; this states it.
///
/// Three details decide whether the result reads as a native floating surface
/// or as a rectangle pasted onto the content:
///
/// - **A drop shadow.** Every AppKit floating surface has one. A card hosted
///   in our own window gets none for free. `compositingGroup` flattens the
///   card first so the shadow is cast by the finished rounded card rather
///   than by each layer inside it.
/// - **`strokeBorder`, not `stroke`.** A centred stroke puts half its width
///   outside the shape, and the clip that rounds the card then removes that
///   half — leaving a soft half-point hairline where a crisp edge belongs.
///   Drawing the border inside the path keeps the full width.
/// - **The material, untinted.** Painting a colour over `.popover` flattens
///   the vibrancy the material exists to provide, which is what made the card
///   read as a grey plate. If contrast is short somewhere, change the
///   material rather than tinting it back.
extension View {
  func floatingCard(cornerRadius: CGFloat) -> some View {
    modifier(FloatingCard(cornerRadius: cornerRadius))
  }
}

private struct FloatingCard: ViewModifier {
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    return
      content
      // Real AppKit glass rather than SwiftUI's `Material` shim.
      // `.withinWindow` samples the app content beneath the overlay rather
      // than the desktop behind the window.
      .background(
        VisualEffectBackground(material: .popover, blendingMode: .withinWindow)
          .clipShape(shape)
      )
      .clipShape(shape)
      .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
      .compositingGroup()
      .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
  }
}
