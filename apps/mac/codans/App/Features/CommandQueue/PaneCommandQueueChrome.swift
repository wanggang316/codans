import CodansCore
import SwiftUI

/// Laid over a whole pane card: the actions menu button in the card header,
/// left of the close button, and the queued-commands list under the header.
///
/// The list opens only on request, from the queue badge in the header. It
/// never opens by itself over the terminal: a queued command is waiting,
/// not news, and the badge already says how many there are.
struct PaneCommandQueueChrome: View {
  let paneID: PaneID
  let surface: PaneSurface?
  /// Follows the visibility of the other header actions.
  var showsMenu: Bool = true
  /// A click on the menu also focuses its pane, so the header actions stay
  /// up while the menu is open.
  var onMenuInteraction: () -> Void = {}
  /// Whether the queued-commands list is open. The header's queue badge
  /// toggles it.
  @Binding var isQueueListShown: Bool

  @Environment(HierarchyManager.self) private var hierarchyManager

  private var entries: [QueuedCommand] {
    hierarchyManager.catalog.pane(paneID)?.commandQueue ?? []
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      if isQueueListShown, !entries.isEmpty {
        PaneCommandQueueList(paneID: paneID, entries: entries) {
          isQueueListShown = false
        }
        .padding(.top, PaneCardMetrics.headerHeight + 2)
        .padding(.horizontal, PaneCardMetrics.headerHorizontalInset)
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
      }
      if showsMenu {
        PaneActionsMenuButton(
          paneID: paneID, surface: surface, onMenuPressed: onMenuInteraction
        )
        // Puts the menu button in the header slot that `PaneCardHeader`
        // reserves left of its close button.
        .padding(.trailing, PaneCardMetrics.menuSlotTrailingOffset)
        .padding(.top, PaneCardMetrics.actionButtonTop)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    .animation(.easeOut(duration: 0.14), value: isQueueListShown && !entries.isEmpty)
    // The list closes with its last command.
    .onChange(of: entries.isEmpty) { _, isEmpty in
      if isEmpty { isQueueListShown = false }
    }
  }
}

/// The queued commands of one pane, newest last, in a card under the
/// header's queue badge. Opaque, so terminal output never reads through it.
private struct PaneCommandQueueList: View {
  let paneID: PaneID
  let entries: [QueuedCommand]
  let onDismiss: () -> Void

  @Environment(HierarchyManager.self) private var hierarchyManager

  private static let width: CGFloat = 380
  private static let maxListHeight: CGFloat = 264
  private static let cornerRadius: CGFloat = 10

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Text("Queued Commands")
          .font(.system(size: 12, weight: .semibold))
        Text("\(entries.count)")
          .font(.system(size: 11, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Button("Clear All") { hierarchyManager.setCommandQueue([], for: paneID) }
          .buttonStyle(.borderless)
          .font(.system(size: 11))
      }
      .padding(.horizontal, 12)
      .frame(height: 34)
      Divider()
      ScrollView {
        VStack(spacing: 0) {
          ForEach(entries) { entry in
            PaneCommandQueueRow(entry: entry) {
              hierarchyManager.setCommandQueue(entries.filter { $0.id != entry.id }, for: paneID)
            }
          }
        }
        .padding(4)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: Self.maxListHeight)
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: Self.width)
    .background {
      RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        .fill(Color(nsColor: .windowBackgroundColor))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
    }
    .overlay {
      RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
    }
    .dismissOnClickOutside(isPresented: true, onDismiss: onDismiss)
    .accessibilityIdentifier("pane.command_queue")
  }
}

/// One queued command: what will be sent, and when. The remove button shows
/// on hover, so a list of commands does not read as a column of buttons.
private struct PaneCommandQueueRow: View {
  let entry: QueuedCommand
  let onRemove: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: entry.timing.fireDate == nil ? "arrow.turn.down.right" : "clock")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(width: 16)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.text.split(whereSeparator: \.isNewline).joined(separator: " ⏎ "))
          .font(.system(size: 12, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.tail)
        Text(CommandQueueStyle.description(of: entry.timing))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: onRemove) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 20, height: 20)
          .background(Circle().fill(Color.primary.opacity(PaneCardMetrics.hoverFillOpacity)))
          .contentShape(.circle)
      }
      .buttonStyle(.plain)
      .opacity(isHovered ? 1 : 0)
      .help("Remove")
      .accessibilityLabel("Remove queued command")
    }
    .padding(.horizontal, 8)
    .frame(height: 44)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.primary.opacity(isHovered ? 0.05 : 0))
    )
    .contentShape(.rect)
    .onHover { isHovered = $0 }
    .help(entry.text)
  }
}
