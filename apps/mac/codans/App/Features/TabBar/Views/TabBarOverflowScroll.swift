import SwiftUI
import CodansCore

/// Horizontal scroll host for the chip row. Sits between `TabBarView` and
/// `TabBarRowView` so the container owns the scroll / overflow-shadow
/// logic while the row keeps its drag-and-divider concerns tight.
///
/// - Scrollbar hidden so the bar reads as a continuous ribbon.
/// - 16-pt gradient shadows mask content that bleeds off either edge;
///   they hide once the row is flush with the matching edge so empty
///   space never fades.
/// - Selected-tab auto-scrolls into view (center anchor) with a short
///   easeInOut on `activeTabID` changes, matching the plan.
struct TabBarOverflowScroll<Content: View>: View {
  let activeTabID: TabID?
  @ViewBuilder let content: () -> Content

  @State private var atLeadingEdge: Bool = true
  @State private var atTrailingEdge: Bool = true

  var body: some View {
    ScrollViewReader { proxy in
      GeometryReader { container in
        ScrollView(.horizontal, showsIndicators: false) {
          content()
            .background(
              GeometryReader { contentGeo in
                Color.clear
                  .preference(
                    key: TabBarOverflowGeometryKey.self,
                    value: TabBarOverflowGeometry(
                      contentWidth: contentGeo.size.width,
                      offset: -contentGeo.frame(in: .named(tabBarOverflowCoordinateSpace)).origin.x
                    )
                  )
              }
            )
        }
        .coordinateSpace(name: tabBarOverflowCoordinateSpace)
        .onPreferenceChange(TabBarOverflowGeometryKey.self) { geo in
          let maxOffset = max(0, geo.contentWidth - container.size.width)
          atLeadingEdge = geo.offset <= 0.5
          atTrailingEdge = geo.offset >= maxOffset - 0.5
        }
        .overlay(alignment: .leading) { leadingShadow }
        .overlay(alignment: .trailing) { trailingShadow }
        .onChange(of: activeTabID) { _, newID in
          guard let newID else { return }
          withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(newID, anchor: .center)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var leadingShadow: some View {
    if !atLeadingEdge {
      LinearGradient(
        colors: [Color.black.opacity(0.15), .clear],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: 16)
      .allowsHitTesting(false)
    }
  }

  @ViewBuilder
  private var trailingShadow: some View {
    if !atTrailingEdge {
      LinearGradient(
        colors: [.clear, Color.black.opacity(0.15)],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: 16)
      .allowsHitTesting(false)
    }
  }

}

// File-private so the coordinate-space sentinel does not leak into the
// rest of the module. Lives at top level rather than `static let` because
// generic types cannot host static stored properties.
private let tabBarOverflowCoordinateSpace = "TabBarOverflowScroll"

/// Preference payload carrying the chip-row content width + its current
/// horizontal offset inside the scroll. Combined with the outer container
/// width, these drive the leading / trailing shadow visibility.
private struct TabBarOverflowGeometry: Equatable {
  var contentWidth: CGFloat
  var offset: CGFloat
}

private struct TabBarOverflowGeometryKey: PreferenceKey {
  static let defaultValue = TabBarOverflowGeometry(contentWidth: 0, offset: 0)
  static func reduce(value: inout TabBarOverflowGeometry, nextValue: () -> TabBarOverflowGeometry) {
    value = nextValue()
  }
}
