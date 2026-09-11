import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CodansCore

/// Settings → Projects → General → Icon.
///
/// A preview button that opens a popover offering the three states
/// `Project.icon` can hold: the built-in folder default (`nil`), an SF Symbol,
/// or imported artwork. The picker owns no persisted state — every choice
/// writes straight through `selection`, matching `ProjectColorSwatchRow` right
/// below it.
struct ProjectIconPicker: View {
  @Binding var selection: ProjectIcon?
  /// The Project's color, so the preview and the grid show the icon in the
  /// tint it will actually render with in the sidebar.
  let color: ProjectColor?

  @State private var isPresented = false
  /// Live text of the "SF Symbol name" field. Held locally rather than
  /// derived from `selection` because a half-typed name doesn't resolve to a
  /// symbol, and writing those through would blank the sidebar glyph on every
  /// keystroke. Only resolvable names reach the catalog.
  @State private var symbolDraft: String = ""
  /// Set when an import is rejected or fails, cleared on the next attempt.
  @State private var importError: String?

  /// Project-flavoured grid: repository / stack / domain glyphs rather than
  /// the run-and-build vocabulary `SFSymbolPicker.presets` carries.
  static let symbols: [String] = [
    "folder", "folder.fill", "shippingbox", "shippingbox.fill",
    "cube", "cube.fill", "square.stack.3d.up", "building.2",
    "hammer", "wrench.and.screwdriver", "gearshape", "cpu",
    "chevron.left.forwardslash.chevron.right", "terminal", "command", "curlybraces",
    "arrow.triangle.branch", "server.rack", "externaldrive", "cylinder.split.1x2",
    "globe", "network", "antenna.radiowaves.left.and.right", "bolt",
    "sparkles", "wand.and.stars", "brain", "ladybug",
    "doc.text", "book", "graduationcap", "flask",
    "paintbrush", "camera", "music.note", "gamecontroller",
    "cart", "creditcard", "chart.bar", "heart",
    "star", "flag", "tag", "bookmark",
  ]

  var body: some View {
    HStack(spacing: 8) {
      Button {
        symbolDraft = currentSymbolName
        isPresented = true
      } label: {
        HStack(spacing: 6) {
          ProjectIconView(icon: selection, color: color, isExpanded: true, size: 14)
          Text(summary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(minWidth: 140, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.bordered)
      .accessibilityLabel("Project icon: \(summary)")
      .popover(isPresented: $isPresented, arrowEdge: .bottom) { popoverBody }
      Spacer(minLength: 0)
    }
  }

  // MARK: - Popover

  private var popoverBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Button("Use Folder") { commit(nil) }
          .disabled(selection == nil)
        Button("Choose File…") { chooseFile() }
        Spacer(minLength: 0)
      }

      if let importError {
        Text(importError)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()

      SFSymbolPicker(
        selection: symbolBinding,
        highlight: color?.swiftUIColor ?? .accentColor,
        symbols: Self.symbols
      )

      Text(
        "Vector artwork (SVG, PDF) is tinted with the project color. "
          + "Bitmaps (PNG, JPEG, HEIC, TIFF, GIF, ICNS) keep their own colors."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(width: 380)
  }

  /// Bridges `SFSymbolPicker`'s plain `String` binding onto the enum. Writes
  /// are filtered to names the system can actually resolve, so typing toward
  /// `"terminal"` never persists `"ter"` as the Project's icon.
  private var symbolBinding: Binding<String> {
    Binding(
      get: { symbolDraft },
      set: { newValue in
        symbolDraft = newValue
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
          NSImage(systemSymbolName: trimmed, accessibilityDescription: nil) != nil
        else { return }
        commit(.symbol(trimmed))
      }
    )
  }

  // MARK: - Actions

  private func chooseFile() {
    importError = nil
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Choose an image to use as this project's icon."
    panel.allowedContentTypes = Self.allowedContentTypes
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let fileName = try ProjectIconStore.importIcon(from: url)
      ProjectIconImageCache.invalidate(fileName: fileName)
      commit(.custom(fileName: fileName))
    } catch let error as ProjectIconStore.ImportError {
      switch error {
      case .unsupportedFormat(let ext):
        importError = ext.isEmpty
          ? "That file has no recognizable image extension."
          : "Icons can't be made from .\(ext) files."
      }
    } catch {
      importError = "Couldn't copy that image: \(error.localizedDescription)"
    }
  }

  private func commit(_ icon: ProjectIcon?) {
    selection = icon
    if icon == nil { symbolDraft = "" }
  }

  // MARK: - Derived

  /// Content types the open panel offers, derived from the same extension
  /// set `ProjectIconStore` validates against so the panel can never hand
  /// back a file the import step then rejects.
  private static let allowedContentTypes: [UTType] = ProjectIcon.supportedExtensions
    .sorted()
    .compactMap { UTType(filenameExtension: $0) }

  /// SF Symbol name behind the current selection, or the default folder glyph
  /// so opening the popover pre-fills the field with something meaningful.
  private var currentSymbolName: String {
    if case .symbol(let name) = selection { return name }
    return ""
  }

  private var summary: String {
    switch selection {
    case .none: "Folder (default)"
    case .symbol(let name): name
    case .custom(let fileName): "Custom — .\(ProjectIcon.normalizedExtension(of: fileName))"
    }
  }
}
