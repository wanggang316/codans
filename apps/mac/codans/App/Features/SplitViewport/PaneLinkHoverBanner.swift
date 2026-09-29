import SwiftUI

/// The link under the pointer (⌘-hover, or any OSC 8 hyperlink), shown in a
/// bottom corner of the pane the way Ghostty's own macOS app shows it:
/// bottom-leading by default, hopping to bottom-trailing while the pointer
/// is over the banner so it never covers the text being pointed at.
struct PaneLinkHoverBanner: View {
  let surface: PaneSurface
  @State private var isHoveringLeading = false

  private static let padding: CGFloat = 5
  private static let cornerRadius: CGFloat = 9

  var body: some View {
    if let link = surface.info.mouseOverLink, !link.isEmpty {
      ZStack {
        HStack {
          Spacer()
          VStack(alignment: .leading) {
            Spacer()
            label(link, corner: .init(topLeading: Self.cornerRadius))
              .opacity(isHoveringLeading ? 1 : 0)
          }
        }
        HStack {
          VStack(alignment: .leading) {
            Spacer()
            label(link, corner: .init(topTrailing: Self.cornerRadius))
              .opacity(isHoveringLeading ? 0 : 1)
              .onHover { isHoveringLeading = $0 }
          }
          Spacer()
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: link))
    }
  }

  private func label(_ link: String, corner: RectangleCornerRadii) -> some View {
    Text(verbatim: link)
      .padding(Self.padding)
      .background(UnevenRoundedRectangle(cornerRadii: corner).fill(.background))
      .lineLimit(1)
      .truncationMode(.middle)
  }
}
