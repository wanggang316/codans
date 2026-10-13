import AppKit
import SwiftUI

/// What the hover card under a tab chip shows: the tab's full title, which
/// the chip truncates, and the process the tab runs, if any.
struct TabHoverCardContent: Equatable {
  var title: String
  var process: WorktreeProcessEntry?
}

/// The card's content. Title in the chip's own typography, not bold; the
/// optional second row is the running process's logo and name. The glass
/// behind it belongs to the panel, see `TabHoverCardPanel`.
struct TabHoverCardView: View {
  let content: TabHoverCardContent

  /// Widest the card grows before the title wraps. Applied as the size
  /// proposal when the presenter measures the card.
  static let maxWidth: CGFloat = 320
  /// The chip's capsule radius, so the card reads as the chip's sibling.
  static let cornerRadius: CGFloat = TabBarMetrics.chipHeight / 2

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(content.title)
        .font(.system(size: TabBarMetrics.titleFontSize))
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      if let process = content.process {
        HStack(spacing: 5) {
          WorktreeProcessIconView(entry: process)
          Text(process.name)
            .font(.system(size: TabBarMetrics.titleFontSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
  }
}

/// Holds a chip's AppKit view so the card can be placed under it, and
/// identifies the chip that owns the card.
@MainActor
final class TabHoverCardAnchor {
  weak var view: NSView?
}

/// Thin AppKit view stamped behind a chip that hands its `NSView` to the
/// chip's `TabHoverCardAnchor`.
struct TabHoverCardAnchorView: NSViewRepresentable {
  let anchor: TabHoverCardAnchor

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    anchor.view = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    anchor.view = nsView
  }
}

/// Shows one hover card at a time below the hovered tab chip, as Safari
/// does: the first card waits `showDelay`; while a card is up, or just
/// went down, moving to another chip swaps it at once. The card lives in
/// a non-activating child panel that ignores the mouse, so it never takes
/// focus from the terminal and never blocks the bar.
@MainActor
final class TabHoverCardPresenter {
  static let shared = TabHoverCardPresenter()

  /// After the card goes down, hovering another chip within this window
  /// brings it back without the delay.
  static let warmInterval: TimeInterval = 0.3
  /// Gap between the chip's bottom edge and the card.
  static let verticalGap: CGFloat = 4

  private let showDelay: Duration
  private let isAppActive: () -> Bool
  private var panel: TabHoverCardPanel?
  private var hosting: NSHostingController<TabHoverCardView>?
  private weak var owner: TabHoverCardAnchor?
  /// A pressed chip shows no card until the pointer leaves it.
  private weak var suppressed: TabHoverCardAnchor?
  private(set) var title = ""
  private var process: () -> WorktreeProcessEntry? = { nil }
  private var showTask: Task<Void, Never>?
  private var hiddenAt: Date?

  init(
    showDelay: Duration = .milliseconds(500), isAppActive: @escaping () -> Bool = { NSApp.isActive }
  ) {
    self.showDelay = showDelay
    self.isAppActive = isAppActive
  }

  /// Screen frame of the card while it shows.
  var visibleFrame: CGRect? {
    guard let panel, panel.isVisible else { return nil }
    return panel.frame
  }

  func hoverBegan(
    _ anchor: TabHoverCardAnchor, title: String,
    process: @escaping () -> WorktreeProcessEntry?
  ) {
    guard suppressed !== anchor, isAppActive() else { return }
    showTask?.cancel()
    owner = anchor
    self.title = title
    self.process = process
    if isWarm {
      present()
      return
    }
    let delay = showDelay
    showTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self, self.owner === anchor else { return }
      self.present()
    }
  }

  func hoverEnded(_ anchor: TabHoverCardAnchor) {
    if suppressed === anchor { suppressed = nil }
    guard owner === anchor else { return }
    hide()
  }

  /// Keeps a chip's card title in step with the chip while it is shown.
  func titleChanged(_ anchor: TabHoverCardAnchor, to title: String) {
    guard owner === anchor else { return }
    self.title = title
    if visibleFrame != nil { render() }
  }

  /// A press selects or starts dragging the chip; get out of the way.
  func pressed(_ anchor: TabHoverCardAnchor) {
    suppressed = anchor
    if owner === anchor { hide() }
  }

  private var isWarm: Bool {
    if visibleFrame != nil { return true }
    guard let hiddenAt else { return false }
    return Date().timeIntervalSince(hiddenAt) < Self.warmInterval
  }

  private func hide() {
    showTask?.cancel()
    showTask = nil
    owner = nil
    guard let panel, panel.isVisible else { return }
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
    hiddenAt = Date()
  }

  private func present() {
    guard let window = owner?.view?.window, window.isVisible else {
      hide()
      return
    }
    let panel = self.panel ?? makePanel()
    if panel.parent !== window {
      panel.parent?.removeChildWindow(panel)
      window.addChildWindow(panel, ordered: .above)
    }
    render()
    panel.orderFront(nil)
  }

  /// Fills the card, sizes it to its content and puts it under the owning
  /// chip, centered on it, kept on the chip's screen. The process
  /// read is tracked, so the card follows the process registry while up.
  private func render() {
    guard let panel, let hosting, let view = owner?.view, let window = view.window else { return }
    let content = withObservationTracking {
      TabHoverCardContent(title: title, process: process())
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self, self.visibleFrame != nil else { return }
        self.render()
      }
    }
    hosting.rootView = TabHoverCardView(content: content)
    let size = hosting.sizeThatFits(
      in: CGSize(width: TabHoverCardView.maxWidth, height: .greatestFiniteMagnitude))
    let chip = window.convertToScreen(view.convert(view.bounds, to: nil))
    var origin = CGPoint(
      x: (chip.midX - size.width / 2).rounded(), y: chip.minY - Self.verticalGap - size.height)
    if let visible = window.screen?.visibleFrame {
      origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
      origin.y = max(origin.y, visible.minY)
    }
    panel.setFrame(CGRect(origin: origin, size: size), display: true)
    // The shadow is cut from the mask once; recut it for the new size.
    panel.invalidateShadow()
  }

  private func makePanel() -> TabHoverCardPanel {
    let panel = TabHoverCardPanel()
    let hosting = NSHostingController(
      rootView: TabHoverCardView(content: .init(title: title, process: nil)))
    hosting.sizingOptions = []
    // A hosting view that is the window's content view sizes the window
    // itself, inside its own layout pass; nested, it only fills the panel.
    hosting.view.autoresizingMask = [.width, .height]
    panel.contentView?.addSubview(hosting.view)
    self.panel = panel
    self.hosting = hosting
    return panel
  }
}

/// Borderless, transparent, click-through panel that can never become key
/// or main. Its content view is the card's glass: an `NSVisualEffectView`
/// masked to the card's rounded shape. The window server cuts the shadow
/// from that mask, so glass and shadow share one outline. A SwiftUI
/// material plus stroke drew a second edge inside the system shadow's rim.
private final class TabHoverCardPanel: NSPanel {
  init() {
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    let glass = NSVisualEffectView()
    glass.material = .popover
    glass.blendingMode = .behindWindow
    glass.state = .active
    glass.maskImage = Self.mask(cornerRadius: TabHoverCardView.cornerRadius)
    contentView = glass
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    ignoresMouseEvents = true
    hidesOnDeactivate = true
    isReleasedWhenClosed = false
    animationBehavior = .none
    collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
  }

  /// Stretchable rounded-rect mask: only the corners keep their shape.
  private static func mask(cornerRadius radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
