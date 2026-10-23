import CodansCore
import SwiftUI

/// Shares Tab-local visibility between the floating list and its restore button.
struct PaneCommandQueueChrome: View {
  let contentID: ContentID

  @SceneStorage private var isHidden: Bool
  @Environment(HierarchyManager.self) private var hierarchyManager
  @State private var isExpanded = false
  @State private var requestedPage = 0

  /// Chrome box of the restore button.
  private static let buttonSize: CGFloat = 30
  private static let buttonCornerRadius: CGFloat = 8
  private static let buttonInset: CGFloat = 6

  init(contentID: ContentID) {
    self.contentID = contentID
    _isHidden = SceneStorage(wrappedValue: false, "commandQueue.hidden.\(contentID)")
  }

  private var entries: [QueuedCommand] {
    hierarchyManager.catalog.content(contentID)?.terminal?.commandQueue ?? []
  }

  var body: some View {
    GeometryReader { geometry in
      let availableHeight = max(0, geometry.size.height - 28)
      let page = CommandQueuePage(
        entryCount: entries.count, availableHeight: availableHeight,
        expanded: isExpanded, requestedPage: requestedPage,
      )
      ZStack(alignment: .topTrailing) {
        if !isHidden, !entries.isEmpty,
          availableHeight >= CommandQueuePage.chromeHeight + CommandQueuePage.rowHeight
        {
          panel(page)
            .frame(maxWidth: 560)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, alignment: .top)
        } else if isHidden, !entries.isEmpty {
          restoreButton
            .padding(Self.buttonInset)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      .onChange(of: page.index) { _, index in requestedPage = index }
    }
  }

  /// Shows the hidden list again without opening the composer.
  private var restoreButton: some View {
    Button {
      isHidden = false
    } label: {
      VStack(spacing: 1) {
        Image(systemName: CommandQueueStyle.symbol)
          .font(.system(size: 11))
          .accessibilityHidden(true)
        Text("\(entries.count)")
          .font(.system(size: 9, weight: .semibold))
          .monospacedDigit()
      }
      .foregroundStyle(Color.accentColor)
      .frame(width: Self.buttonSize, height: Self.buttonSize)
      .background(buttonChrome)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Show queued commands")
    .accessibilityIdentifier("pane.command_queue.show")
    .accessibilityLabel("Show command queue, \(queuedPhrase)")
  }

  /// Glass chip without a shadow: terminal output sits right behind the
  /// button, so the blur stops glyphs from reading through it.
  private var buttonChrome: some View {
    let shape = RoundedRectangle(cornerRadius: Self.buttonCornerRadius, style: .continuous)
    return VisualEffectBackground(material: .popover, blendingMode: .withinWindow)
      .clipShape(shape)
      .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
  }

  private var queuedPhrase: String {
    entries.count == 1 ? "1 queued command" : "\(entries.count) queued commands"
  }

  private func panel(_ page: CommandQueuePage) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("Queued (\(entries.count))")
          .fontWeight(.medium)
          .lineLimit(1)
        Spacer(minLength: 0)
        Button("Clear All") { hierarchyManager.setCommandQueue([], for: contentID) }
          .foregroundStyle(.secondary)
        Button {
          isHidden = true
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(QueueDismissButtonStyle())
        .help("Hide queued commands")
        .accessibilityLabel("Hide queued commands")
      }
      .frame(height: 28)
      ForEach(Array(entries[page.range])) { entry in
        row(entry)
      }
      if entries.count > page.range.count || isExpanded {
        footer(page)
          .frame(height: 28)
      }
    }
    .font(.system(size: 11))
    .buttonStyle(.plain)
    .padding(10)
    .floatingCard(cornerRadius: 10)
    .accessibilityIdentifier("pane.command_queue")
  }

  private func footer(_ page: CommandQueuePage) -> some View {
    HStack(spacing: 8) {
      Button(isExpanded ? "Show Less" : "Show More") {
        isExpanded.toggle()
        requestedPage = 0
      }
      Spacer(minLength: 0)
      if isExpanded, page.count > 1 {
        Button {
          requestedPage = page.index - 1
        } label: {
          Image(systemName: "chevron.left")
        }
        .disabled(page.index == 0)
        .accessibilityLabel("Previous queue page")
        Text("\(page.index + 1) / \(page.count)")
          .monospacedDigit()
        Button {
          requestedPage = page.index + 1
        } label: {
          Image(systemName: "chevron.right")
        }
        .disabled(page.index + 1 == page.count)
        .accessibilityLabel("Next queue page")
      }
    }
    .foregroundStyle(.secondary)
  }

  private func row(_ entry: QueuedCommand) -> some View {
    HStack(spacing: 8) {
      Image(systemName: entry.timing.fireDate == nil ? "arrow.turn.down.right" : "clock")
        .accessibilityHidden(true)
        .foregroundStyle(.secondary)
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.text.split(whereSeparator: \.isNewline).joined(separator: " ⏎ "))
          .font(.system(size: 12, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.tail)
        Text(CommandQueueStyle.description(of: entry.timing))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        hierarchyManager.setCommandQueue(entries.filter { $0.id != entry.id }, for: contentID)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(QueueDismissButtonStyle())
      .accessibilityLabel("Remove queued command")
    }
    .frame(height: CommandQueuePage.rowHeight)
    .help(entry.text)
  }
}

/// The full square is interactive, including the space around the glyph.
private struct QueueDismissButtonStyle: ButtonStyle {
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(width: 28, height: 28)
      .background {
        RoundedRectangle(cornerRadius: 6)
          .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (isHovered ? 0.08 : 0)))
      }
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
  }
}
