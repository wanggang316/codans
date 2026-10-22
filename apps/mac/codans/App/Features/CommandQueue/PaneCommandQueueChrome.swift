import CodansCore
import SwiftUI

/// Shares pane-local visibility between the floating list and its restore button.
struct PaneCommandQueueChrome: View {
  let paneID: PaneID
  let surface: PaneSurface?

  @SceneStorage private var isHidden: Bool
  @Environment(HierarchyManager.self) private var hierarchyManager
  @State private var isExpanded = false
  @State private var requestedPage = 0

  init(paneID: PaneID, surface: PaneSurface?) {
    self.paneID = paneID
    self.surface = surface
    _isHidden = SceneStorage(wrappedValue: false, "commandQueue.hidden.\(paneID)")
  }

  private var entries: [QueuedCommand] {
    hierarchyManager.catalog.pane(paneID)?.commandQueue ?? []
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
            .padding(.leading, 14)
            .padding(.trailing, 58)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        PaneHUDView(paneID: paneID, surface: surface) {
          isHidden = false
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      .onChange(of: page.index) { _, index in requestedPage = index }
    }
  }

  private func panel(_ page: CommandQueuePage) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("Queued (\(entries.count))")
          .fontWeight(.medium)
          .lineLimit(1)
        Spacer(minLength: 0)
        Button("Clear All") { hierarchyManager.setCommandQueue([], for: paneID) }
          .foregroundStyle(.secondary)
        Button {
          isHidden = true
        } label: {
          Image(systemName: "minus")
            .frame(width: 20, height: 24)
        }
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
        hierarchyManager.setCommandQueue(entries.filter { $0.id != entry.id }, for: paneID)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .accessibilityLabel("Remove queued command")
    }
    .frame(height: CommandQueuePage.rowHeight)
    .help(entry.text)
  }
}
