import CodansCore
import ComposableArchitecture
import SwiftUI

/// Title row at the top of a pane card: the pane's glyph and live title on
/// the leading side, split / close actions on the trailing side.
///
/// The header is also the pane's grab handle: in a multi-pane Tab a drag
/// that starts on it moves the pane, the same drag the drop targets in
/// `LeafView` accept. A click focuses the pane.
///
/// The owner decides when the actions show. The actions menu button is not
/// drawn here: `PaneCommandQueueChrome` lays it over the slot this header
/// leaves free left of the close button, because its expanded card has to
/// draw above the terminal.
struct PaneCardHeader: View {
  let paneID: PaneID
  let tabID: TabID
  /// The title row is draggable only when there is another pane to move
  /// next to.
  let isSplit: Bool
  let isFocused: Bool
  let showsActions: Bool
  let onFocus: () -> Void
  let onSplit: (SplitTree<PaneID>.NewDirection) -> Void
  let onClose: () -> Void

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(PaneDropHighlight.self) private var dropHighlight
  @Dependency(TerminalClient.self) private var terminalClient

  /// Pointer over the glyph and title. In a split Tab this shows the move
  /// affordance.
  @State private var isHoveringTitle = false

  var body: some View {
    HStack(spacing: 0) {
      titleChip
      Spacer(minLength: 8)
      if showsActions {
        actions
          .transition(.opacity)
      }
    }
    .padding(.leading, PaneCardMetrics.headerHorizontalInset - PaneCardMetrics.titleChipInset)
    .padding(.trailing, PaneCardMetrics.headerHorizontalInset)
    .frame(height: PaneCardMetrics.headerHeight)
    .contentShape(.rect)
    .onTapGesture(perform: onFocus)
    .accessibilityAddTraits(.isButton)
    .modifier(PaneHeaderDragSource(paneID: paneID, isEnabled: isSplit, highlight: dropHighlight))
  }

  /// Glyph and title. When the pane can move, hovering them swaps the glyph
  /// for a move mark on a capsule fill, to show the drag handle.
  private var titleChip: some View {
    let showsMoveAffordance = isSplit && isHoveringTitle
    return HStack(spacing: 6) {
      Group {
        if showsMoveAffordance {
          Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: PaneCardMetrics.headerIconSize - 1, weight: .medium))
            .foregroundStyle(.primary)
            .accessibilityHidden(true)
        } else {
          glyph
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: PaneCardMetrics.headerIconSize, height: PaneCardMetrics.headerIconSize)
      Text(title)
        .font(.system(size: PaneCardMetrics.headerTitleFontSize, weight: .medium))
        .foregroundStyle(isFocused ? .primary : .secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.horizontal, PaneCardMetrics.titleChipInset)
    .frame(height: PaneCardMetrics.titleChipHeight)
    .background(
      Capsule()
        .fill(Color.primary.opacity(showsMoveAffordance ? 0.06 : 0))
    )
    .contentShape(.capsule)
    .onHover { isHoveringTitle = $0 }
    .animation(.easeOut(duration: 0.12), value: showsMoveAffordance)
  }

  private var actions: some View {
    HStack(spacing: PaneCardMetrics.actionSpacing) {
      PaneCardHeaderButton(systemImage: "square.righthalf.filled", help: "Split Right") {
        onSplit(.right)
      }
      PaneCardHeaderButton(systemImage: "square.bottomhalf.filled", help: "Split Down") {
        onSplit(.down)
      }
      // Actions menu slot, see the type comment.
      Color.clear
        .frame(width: PaneCardMetrics.actionButtonSize, height: PaneCardMetrics.actionButtonSize)
      PaneCardHeaderButton(systemImage: "xmark", help: "Close Pane", action: onClose)
    }
  }

  @ViewBuilder
  private var glyph: some View {
    if let kind = pane?.agentKind {
      StoredIconGlyph(icon: TabIconRef.icon(for: kind), markSize: PaneCardMetrics.headerIconSize)
    } else {
      Image(systemName: "terminal")
        .font(.system(size: PaneCardMetrics.headerIconSize - 2))
        .accessibilityHidden(true)
    }
  }

  private var pane: Pane? {
    hierarchyManager.catalog.pane(paneID)
  }

  /// Live OSC title first, then the live working directory, then the
  /// persisted working directory, so a cold pane is never untitled.
  private var title: String {
    if let surface = terminalClient.surface(paneID) {
      let info = surface.info
      // Read every observable property so a later push on any of them
      // re-renders the header.
      let titleValue = info.title
      let pwdValue = info.pwd
      if let titleValue, !titleValue.isEmpty { return titleValue }
      if let pwdValue, !pwdValue.isEmpty {
        return (pwdValue as NSString).abbreviatingWithTildeInPath
      }
    }
    if let directory = pane?.workingDirectory, !directory.isEmpty {
      return (directory as NSString).abbreviatingWithTildeInPath
    }
    return "Terminal"
  }
}

/// Makes the header a pane drag source. A single-pane Tab has nowhere to
/// drop the pane, so there the header starts no drag at all.
private struct PaneHeaderDragSource: ViewModifier {
  let paneID: PaneID
  let isEnabled: Bool
  let highlight: PaneDropHighlight

  func body(content: Content) -> some View {
    if isEnabled {
      content.onDrag {
        // Arm the highlight for this drag and clear any stale state before
        // the provider is handed to the system.
        highlight.begin()
        return paneDragProvider(for: paneID)
      }
    } else {
      content
    }
  }
}

/// Borderless glyph button with a rounded hover fill.
private struct PaneCardHeaderButton: View {
  let systemImage: String
  let help: String
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: PaneCardMetrics.actionGlyphSize, weight: .regular))
        .foregroundStyle(isHovering ? .primary : .secondary)
        .frame(width: PaneCardMetrics.actionButtonSize, height: PaneCardMetrics.actionButtonSize)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
        )
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
    .onHover { isHovering = $0 }
  }
}
