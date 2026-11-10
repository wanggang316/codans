import AppKit
import SwiftUI

/// Size and place of the floating skill list and its description tooltip,
/// in screen coordinates.
enum ComposerSkillCompletionPanelLayout {
  static let rowHeight: CGFloat = 24
  static let verticalPadding: CGFloat = 5
  static let horizontalPadding: CGFloat = 5
  static let rowHorizontalPadding: CGFloat = 6
  static let iconWidth: CGFloat = 16
  static let iconSpacing: CGFloat = 6
  static let rowFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
  /// Rows shown before the list scrolls.
  static let maxVisibleRows = 9
  /// Space between the editor and the panel.
  static let gap: CGFloat = 4
  static let cornerRadius: CGFloat = 8
  /// Narrowest panel; the editor's width is the widest.
  static let minWidth: CGFloat = 180

  static let tooltipMaxWidth: CGFloat = 320
  static let tooltipHorizontalPadding: CGFloat = 6
  static let tooltipVerticalPadding: CGFloat = 4
  static let tooltipCornerRadius: CGFloat = 5
  /// Space between the panel and the tooltip.
  static let tooltipGap: CGFloat = 4

  static func height(rowCount: Int) -> CGFloat {
    CGFloat(min(max(rowCount, 1), maxVisibleRows)) * rowHeight + 2 * verticalPadding
  }

  /// The widest row among `names` (icon, name, and padding), at least
  /// `minWidth` and at most `maxWidth`. A longer name truncates.
  static func width(names: [String], maxWidth: CGFloat) -> CGFloat {
    let text = names.lazy
      .map { ceil(($0 as NSString).size(withAttributes: [.font: rowFont]).width) }
      .max() ?? 0
    let row = text + iconWidth + iconSpacing + 2 * rowHorizontalPadding + 2 * horizontalPadding
    return min(max(row, minWidth), maxWidth)
  }

  /// The panel's leading edge is the editor's. It opens above the editor,
  /// or below it when the space above on the visible screen is too small.
  static func frame(editor: CGRect, width: CGFloat, height: CGFloat, visible: CGRect) -> CGRect {
    let above = editor.maxY + gap
    let y = above + height <= visible.maxY ? above : editor.minY - gap - height
    return CGRect(x: editor.minX, y: y, width: width, height: height)
  }

  /// Right of the panel, or left of it when there is no room on the right,
  /// with its top on the row's top. It stays on the visible screen.
  static func tooltipFrame(row: CGRect, size: CGSize, panel: CGRect, visible: CGRect) -> CGRect {
    let right = panel.maxX + tooltipGap
    let x = right + size.width <= visible.maxX ? right : panel.minX - tooltipGap - size.width
    let y = max(min(row.maxY, visible.maxY) - size.height, visible.minY)
    return CGRect(x: x, y: y, width: size.width, height: size.height)
  }
}

/// Thin view behind the editor that hands its frame to the presenter. It
/// tells the presenter when SwiftUI moves or resizes it.
final class ComposerSkillCompletionAnchorView: NSView {
  var onGeometryChange: () -> Void = {}

  override func setFrameOrigin(_ newOrigin: NSPoint) {
    super.setFrameOrigin(newOrigin)
    onGeometryChange()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    onGeometryChange()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onGeometryChange()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shows the open skill list in a child panel of the editor's window, as
/// `NSTextView` completion does: the list floats over the window and never
/// changes its layout or size. The panel cannot become key, so the editor
/// keeps focus and its keys keep driving the list. The panel follows the
/// window, and closes with the list, the window, or when the window
/// resigns key. A second child panel shows the description of the
/// highlighted or hovered row beside the list.
@MainActor
final class ComposerSkillCompletionPresenter {
  private typealias Layout = ComposerSkillCompletionPanelLayout

  weak var anchor: NSView?
  /// Closes the list when the window resigns key.
  var onResignKey: () -> Void = {}

  private var names: [String] = []
  private var panel: ComposerSkillCompletionPanel?
  private var hosting: ComposerSkillCompletionHostingView?
  private var tooltip: ComposerSkillCompletionTooltipPanel?
  private var tooltipHosting: NSHostingController<ComposerSkillCompletionTooltip>?
  private var tooltipTarget: ComposerSkillCompletionList.TooltipTarget?
  private weak var observedWindow: NSWindow?
  private var observers: [NSObjectProtocol] = []

  /// Shows `content` for the names of the matches; none hides the panel.
  func update(content: ComposerSkillCompletionList, names: [String]) {
    self.names = names
    guard !names.isEmpty, let window = anchor?.window, window.isVisible else {
      hide()
      return
    }
    var content = content
    content.onTooltipTarget = { [weak self] target in self?.showTooltip(target) }
    let panel = panel ?? makePanel(content)
    hosting?.rootView = content
    observe(window)
    place()
    if panel.parent !== window {
      panel.parent?.removeChildWindow(panel)
      window.addChildWindow(panel, ordered: .above)
    }
    panel.orderFront(nil)
  }

  func place() {
    guard let panel, !names.isEmpty, let anchor, let window = anchor.window else { return }
    let editor = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    let visible = window.screen?.visibleFrame ?? .infinite
    let frame = Layout.frame(
      editor: editor, width: Layout.width(names: names, maxWidth: editor.width),
      height: Layout.height(rowCount: names.count), visible: visible)
    if frame != panel.frame {
      panel.setFrame(frame, display: true)
      // The shadow is cut from the mask once; recut it for the new size.
      panel.invalidateShadow()
    }
    placeTooltip()
  }

  func hide() {
    names = []
    tooltipTarget = nil
    stopObserving()
    hideTooltip()
    guard let panel, panel.parent != nil || panel.isVisible else { return }
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
  }

  private func showTooltip(_ target: ComposerSkillCompletionList.TooltipTarget?) {
    tooltipTarget = target
    placeTooltip()
  }

  /// Puts the tooltip beside its row, or hides it when there is no target
  /// or the row is out of the list's view.
  private func placeTooltip() {
    guard let target = tooltipTarget, let panel, panel.isVisible, let window = panel.parent,
      CGRect(origin: .zero, size: panel.frame.size).intersects(target.rowFrame)
    else {
      hideTooltip()
      return
    }
    let tooltip = tooltip ?? makeTooltip()
    guard let tooltipHosting else { return }
    tooltipHosting.rootView = ComposerSkillCompletionTooltip(text: target.text)
    let size = tooltipHosting.sizeThatFits(
      in: CGSize(width: Layout.tooltipMaxWidth, height: .greatestFiniteMagnitude))
    // The list's frames have a top-left origin.
    let row = CGRect(
      x: panel.frame.minX + target.rowFrame.minX, y: panel.frame.maxY - target.rowFrame.maxY,
      width: target.rowFrame.width, height: target.rowFrame.height)
    let visible = window.screen?.visibleFrame ?? .infinite
    let frame = Layout.tooltipFrame(
      row: row, size: CGSize(width: ceil(size.width), height: ceil(size.height)), panel: panel.frame,
      visible: visible)
    if frame != tooltip.frame {
      tooltip.setFrame(frame, display: true)
      tooltip.invalidateShadow()
    }
    if tooltip.parent !== window {
      tooltip.parent?.removeChildWindow(tooltip)
      window.addChildWindow(tooltip, ordered: .above)
    }
    tooltip.orderFront(nil)
  }

  private func hideTooltip() {
    guard let tooltip, tooltip.parent != nil || tooltip.isVisible else { return }
    tooltip.parent?.removeChildWindow(tooltip)
    tooltip.orderOut(nil)
  }

  private func makePanel(_ content: ComposerSkillCompletionList) -> ComposerSkillCompletionPanel {
    let panel = ComposerSkillCompletionPanel()
    let hosting = ComposerSkillCompletionHostingView(rootView: content)
    hosting.sizingOptions = []
    hosting.autoresizingMask = [.width, .height]
    hosting.frame = panel.contentView?.bounds ?? .zero
    panel.contentView?.addSubview(hosting)
    self.panel = panel
    self.hosting = hosting
    return panel
  }

  private func makeTooltip() -> ComposerSkillCompletionTooltipPanel {
    let tooltip = ComposerSkillCompletionTooltipPanel()
    let hosting = NSHostingController(rootView: ComposerSkillCompletionTooltip(text: ""))
    hosting.sizingOptions = []
    hosting.view.autoresizingMask = [.width, .height]
    hosting.view.frame = tooltip.contentView?.bounds ?? .zero
    tooltip.contentView?.addSubview(hosting.view)
    self.tooltip = tooltip
    tooltipHosting = hosting
    return tooltip
  }

  private func observe(_ window: NSWindow) {
    guard observedWindow !== window else { return }
    stopObserving()
    observedWindow = window
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {
          self?.onResignKey()
          self?.hide()
        }
      },
      center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.hide() }
      },
      center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.place() }
      },
    ]
  }

  private func stopObserving() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    observedWindow = nil
  }
}

/// Puts a `ComposerSkillCompletionPresenter` behind the editor.
struct ComposerSkillCompletionPanelAnchor: NSViewRepresentable {
  let content: ComposerSkillCompletionList
  /// Names of the matches in the open list; empty when the list is closed.
  let names: [String]
  let onResignKey: () -> Void

  func makeCoordinator() -> ComposerSkillCompletionPresenter {
    ComposerSkillCompletionPresenter()
  }

  func makeNSView(context: Context) -> ComposerSkillCompletionAnchorView {
    let view = ComposerSkillCompletionAnchorView()
    let presenter = context.coordinator
    presenter.anchor = view
    view.onGeometryChange = { [weak presenter] in presenter?.place() }
    return view
  }

  func updateNSView(_ view: ComposerSkillCompletionAnchorView, context: Context) {
    let presenter = context.coordinator
    presenter.anchor = view
    presenter.onResignKey = onResignKey
    presenter.update(content: content, names: names)
  }

  static func dismantleNSView(
    _ view: ComposerSkillCompletionAnchorView, coordinator: ComposerSkillCompletionPresenter
  ) {
    coordinator.hide()
  }
}

/// Takes the first click, so a click on a row picks it at once although the
/// panel is never key.
final class ComposerSkillCompletionHostingView: NSHostingView<ComposerSkillCompletionList> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless, non-activating panel with the menu material, masked to a
/// rounded card. The window server cuts the system shadow from the mask.
/// It never becomes key or main, so focus stays in the editor.
final class ComposerSkillCompletionPanel: NSPanel {
  init() {
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    let glass = NSVisualEffectView()
    glass.material = .menu
    glass.blendingMode = .behindWindow
    glass.state = .active
    glass.maskImage = .roundedMask(cornerRadius: ComposerSkillCompletionPanelLayout.cornerRadius)
    contentView = glass
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    hidesOnDeactivate = true
    isReleasedWhenClosed = false
    animationBehavior = .none
    collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Borderless panel in the system tooltip material for the description
/// beside the list. It ignores the mouse and never becomes key or main.
final class ComposerSkillCompletionTooltipPanel: NSPanel {
  init() {
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    let background = NSVisualEffectView()
    background.material = .toolTip
    background.blendingMode = .behindWindow
    background.state = .active
    background.maskImage = .roundedMask(cornerRadius: ComposerSkillCompletionPanelLayout.tooltipCornerRadius)
    contentView = background
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    ignoresMouseEvents = true
    hidesOnDeactivate = true
    isReleasedWhenClosed = false
    animationBehavior = .none
    collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
