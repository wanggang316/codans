import CodansCore
import SwiftUI

/// Grid of bundled tool marks, laid out like `SFSymbolPicker`'s preset grid
/// so the two read as one icon palette in the command icon popover.
struct ToolMarkPicker: View {
  @Binding var selection: ToolMark?
  var highlight: Color = .accentColor

  var body: some View {
    ScrollView {
      LazyVGrid(
        columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 10),
        spacing: 8
      ) {
        ForEach(ToolMark.allCases, id: \.self) { mark in
          Button {
            selection = mark
          } label: {
            CommandIconGlyph(icon: .mark(mark), markSize: 16)
              .foregroundStyle(mark == selection ? highlight : .primary)
              .frame(width: 24, height: 24)
          }
          .buttonStyle(.plain)
          .help(mark.displayName)
          .accessibilityLabel(mark.displayName)
        }
      }
      .padding(12)
    }
    .frame(maxHeight: 124)
  }
}
