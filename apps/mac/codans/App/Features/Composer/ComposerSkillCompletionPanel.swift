import AppKit
import SwiftUI

/// Size and place of the floating skill list, in screen coordinates.
enum ComposerSkillCompletionPanelLayout {
  static let rowHeight: CGFloat = 24
  static let verticalPadding: CGFloat = 5
  static let horizontalPadding: CGFloat = 5
  /// Rows shown before the list scrolls.
  static let maxVisibleRows = 9
  /// Space between the editor and the panel.
  static let gap: CGFloat = 4
  static let cornerRadius: CGFloat = 8

  static func height(rowCount: Int) -> CGFloat {
    CGFloat(min(max(rowCount, 1), maxVisibleRows)) * rowHeight + 2 * verticalPadding
  }

  /// The panel has the editor's width and opens above it, or below it when
  /// the space above on the visible screen is too small.
  static func frame(editor: CGRect, height: CGFloat, visible: CGRect) -> CGRect {
    let above = editor.maxY + gap
    let y = above + height <= visible.maxY ? above : editor.minY - gap - height
    return CGRect(x: editor.minX, y: y, width: editor.width, height: height)
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
/// resigns key.
@MainActor
final class ComposerSkillCompletionPresenter {
  private typealias Layout = ComposerSkillCompletionPanelLayout

  weak var anchor: NSView?
  /// Closes the list when the window resigns key.
  var onResignKey: () -> Void = {}

  private var rowCount = 0
  private var panel: ComposerSkillCompletionPanel?
  private var hosting: ComposerSkillCompletionHostingView?
  private weak var observedWindow: NSWindow?
  private var observers: [NSObjectProtocol] = []

  /// Shows `content` for `rowCount` matches; `0` hides the panel.
  func update(content: ComposerSkillCompletionList, rowCount: Int) {
    self.rowCount = rowCount
    guard rowCount > 0, let window = anchor?.window, window.isVisible else {
      hide()
      return
    }
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
    guard let panel, rowCount > 0, let anchor, let window = anchor.window else { return }
    let editor = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    let visible = window.screen?.visibleFrame ?? .infinite
    let frame = Layout.frame(editor: editor, height: Layout.height(rowCount: rowCount), visible: visible)
    guard frame != panel.frame else { return }
    panel.setFrame(frame, display: true)
    // The shadow is cut from the mask once; recut it for the new size.
    panel.invalidateShadow()
  }

  func hide() {
    rowCount = 0
    stopObserving()
    guard let panel, panel.parent != nil || panel.isVisible else { return }
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
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
  /// Matches in the open list; `0` when the list is closed.
  let rowCount: Int
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
    presenter.update(content: content, rowCount: rowCount)
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
