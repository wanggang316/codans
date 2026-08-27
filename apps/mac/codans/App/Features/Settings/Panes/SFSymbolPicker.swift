import AppKit
import SwiftUI

/// Curated SF Symbol grid plus a free-text field for any symbol the system
/// has and a shortcut into the SF Symbols app.
///
/// Shared by every settings surface that lets the user pick a glyph — the
/// Commands table's icon popover and the Agents pane's profile icon — so the
/// preset set, the "type any symbol" escape hatch, and the app-launch
/// fallback stay in one place.
///
/// The picker owns no state: `selection` is the live symbol name and every
/// pick writes straight through.
struct SFSymbolPicker: View {
  @Binding var selection: String
  /// Colour applied to the currently-selected preset. Callers that carry a
  /// tint (script commands) pass theirs; the rest get the accent colour.
  var highlight: Color = .accentColor

  /// Presets, ordered roughly run → build → status → file-transfer so the
  /// grid reads in bands rather than as an alphabetical dump.
  static let presets: [String] = [
    "terminal", "terminal.fill", "play.fill", "stop.fill",
    "hammer.fill", "shippingbox.fill", "doc.text.fill", "sparkles",
    "bolt.fill", "flame.fill", "wand.and.stars", "wrench.and.screwdriver.fill",
    "checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.triangle.fill", "ladybug.fill",
    "clock.fill", "repeat", "arrow.clockwise", "folder.fill",
    "archivebox.fill", "paperplane.fill", "cloud.fill", "tray.and.arrow.down.fill",
    "tray.and.arrow.up.fill", "icloud.and.arrow.up.fill", "square.and.arrow.up.fill",
    "arrow.triangle.2.circlepath",
    "folder.badge.plus", "doc.badge.plus",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        TextField("SF Symbol name", text: $selection)
          .textFieldStyle(.roundedBorder)
        Button("Open SF Symbols", action: Self.openSFSymbols)
      }

      ScrollView {
        LazyVGrid(
          columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 10),
          spacing: 8
        ) {
          ForEach(Self.presets, id: \.self) { name in
            Button {
              selection = name
            } label: {
              Image(systemName: name)
                .foregroundStyle(name == selection ? highlight : .primary)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .help(name)
          }
        }
        .padding(12)
      }
      .frame(maxHeight: 124)
    }
  }

  /// Launch the SF Symbols app, falling back to the web reference.
  static func openSFSymbols() {
    let workspace = NSWorkspace.shared
    if let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.SFSymbols") {
      workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
      return
    }
    if let url = URL(string: "https://developer.apple.com/sf-symbols/") {
      workspace.open(url)
    }
  }
}
