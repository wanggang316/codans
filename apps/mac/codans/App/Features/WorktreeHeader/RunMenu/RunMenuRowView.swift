import AppKit

/// Custom-view menu row for the Run dropdown. Stock `NSMenuItem`s can neither
/// grow taller nor host a second click target, and this menu needs both:
/// larger rows whose icon matches the button, and a trailing add accessory
/// separate from the row's run action.
///
/// A view-backed item draws everything itself. The selection highlight is a
/// `.selection`-material effect view — the material stock menu items use, so
/// the colour matches them under the menu's translucency — shown while
/// `enclosingMenuItem.isHighlighted` (refreshed by the menu delegate on
/// `willHighlight`). Content is drawn by a canvas above it. AppKit sends a
/// view-backed item's action for neither Return nor AXPress, so the row
/// handles both itself.
final class RunMenuRowView: NSView {
  enum Accessory: Equatable {
    /// Not yet one of the Project's commands — clicking adds it.
    case add
    /// Already added: a status mark, not a separate control.
    case added
  }

  struct Content {
    var icon: NSImage?
    /// Drawn instead of `icon` while the row is highlighted: the tinted glyph
    /// in the highlight's text colour, as a stock item's template image turns.
    var highlightedIcon: NSImage?
    var title: String
    var subtitle: String?
    var trailingText: String?
    var accessory: Accessory?
  }

  var content: Content {
    didSet { canvas.needsDisplay = true }
  }
  var onRun: (() -> Void)?
  var onAdd: (() -> Void)?

  private var isAccessoryHovered = false {
    didSet { if oldValue != isAccessoryHovered { canvas.needsDisplay = true } }
  }

  // Geometry, matched against stock items in the same menu: a 5pt selection
  // inset, icons in the image column, titles in the title column.
  private static let selectionInset: CGFloat = 5
  private static let iconX: CGFloat = 14
  private static let textX: CGFloat = 34
  private static let trailingPadding: CGFloat = 14
  private static let accessorySide: CGFloat = 20

  private static let titleFont = NSFont.menuFont(ofSize: 0)
  private static let subtitleFont = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
  private static let trailingFont = NSFont.menuFont(ofSize: 0)

  private let highlight = NSVisualEffectView()
  private let canvas = Canvas()

  init(content: Content, height: CGFloat) {
    self.content = content
    super.init(frame: NSRect(x: 0, y: 0, width: 10, height: height))
    frame.size.width = fittingWidth
    autoresizingMask = [.width]
    highlight.material = .selection
    highlight.state = .active
    highlight.isEmphasized = true
    highlight.wantsLayer = true
    highlight.layer?.cornerRadius = 5
    highlight.layer?.masksToBounds = true
    highlight.isHidden = true
    highlight.frame = bounds.insetBy(dx: Self.selectionInset, dy: 0)
    highlight.autoresizingMask = [.width, .height]
    addSubview(highlight)
    canvas.owner = self
    canvas.frame = bounds
    canvas.autoresizingMask = [.width, .height]
    addSubview(canvas)
    let tracking = NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(tracking)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var isFlipped: Bool { true }

  /// Narrowest width that shows every part; the menu widens all rows to its
  /// widest one.
  var fittingWidth: CGFloat {
    let title = (content.title as NSString).size(withAttributes: [.font: Self.titleFont]).width
    let subtitle = content.subtitle.map { ($0 as NSString).size(withAttributes: [.font: Self.subtitleFont]).width } ?? 0
    var trailing: CGFloat = 0
    if let text = content.trailingText {
      trailing += (text as NSString).size(withAttributes: [.font: Self.trailingFont]).width + 20
    }
    if content.accessory != nil { trailing += Self.accessorySide + 16 }
    return Self.textX + max(title, subtitle) + trailing + Self.trailingPadding + 8
  }

  private var isHighlighted: Bool {
    enclosingMenuItem?.isHighlighted == true && enclosingMenuItem?.isEnabled == true
  }

  private var accessoryRect: NSRect {
    NSRect(
      x: bounds.maxX - Self.trailingPadding - Self.accessorySide,
      y: (bounds.height - Self.accessorySide) / 2,
      width: Self.accessorySide,
      height: Self.accessorySide
    )
  }

  // MARK: Drawing

  /// The menu delegate marks rows dirty on highlight changes; sync the
  /// effect view and repaint the content with them.
  override var needsDisplay: Bool {
    didSet {
      if needsDisplay {
        highlight.isHidden = !isHighlighted
        canvas.needsDisplay = true
      }
    }
  }

  fileprivate func drawContent() {
    let enabled = enclosingMenuItem?.isEnabled ?? true
    let highlighted = isHighlighted
    highlight.isHidden = !highlighted
    let primary: NSColor =
      highlighted ? .selectedMenuItemTextColor : (enabled ? .labelColor : .disabledControlTextColor)
    let secondary: NSColor =
      highlighted ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.8) : .secondaryLabelColor

    if let icon = highlighted ? (content.highlightedIcon ?? content.icon) : content.icon {
      let box = RunMenuMetrics.iconBox
      let size = Self.aspectFit(icon.size, in: box)
      let rect = NSRect(
        x: Self.iconX + (box - size.width) / 2,
        y: (bounds.height - size.height) / 2,
        width: size.width, height: size.height)
      icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: enabled ? 1 : 0.4, respectFlipped: true, hints: nil)
    }

    var trailingEdge = bounds.maxX - Self.trailingPadding
    if let accessory = content.accessory {
      drawAccessory(accessory, highlighted: highlighted, color: highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor)
      trailingEdge = accessoryRect.minX - 10
    }
    if let text = content.trailingText {
      let attributes: [NSAttributedString.Key: Any] = [.font: Self.trailingFont, .foregroundColor: secondary]
      let size = (text as NSString).size(withAttributes: attributes)
      (text as NSString).draw(
        at: NSPoint(x: trailingEdge - size.width, y: (bounds.height - size.height) / 2), withAttributes: attributes)
      trailingEdge -= size.width + 12
    }

    let textWidth = max(0, trailingEdge - Self.textX)
    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: Self.titleFont, .foregroundColor: primary, .paragraphStyle: Self.truncating,
    ]
    let titleHeight = Self.titleFont.boundingRectForFont.height.rounded(.up)
    if let subtitle = content.subtitle {
      let subtitleAttributes: [NSAttributedString.Key: Any] = [
        .font: Self.subtitleFont, .foregroundColor: secondary, .paragraphStyle: Self.truncating,
      ]
      let subtitleHeight = Self.subtitleFont.boundingRectForFont.height.rounded(.up)
      let top = (bounds.height - titleHeight - subtitleHeight + 2) / 2
      (content.title as NSString).draw(
        in: NSRect(x: Self.textX, y: top, width: textWidth, height: titleHeight), withAttributes: titleAttributes)
      (subtitle as NSString).draw(
        in: NSRect(x: Self.textX, y: top + titleHeight - 2, width: textWidth, height: subtitleHeight),
        withAttributes: subtitleAttributes)
    } else {
      (content.title as NSString).draw(
        in: NSRect(x: Self.textX, y: (bounds.height - titleHeight) / 2, width: textWidth, height: titleHeight),
        withAttributes: titleAttributes)
    }
  }

  private func drawAccessory(_ accessory: Accessory, highlighted: Bool, color: NSColor) {
    let rect = accessoryRect
    if accessory == .add, isAccessoryHovered {
      (highlighted ? NSColor.white.withAlphaComponent(0.25) : NSColor.quaternaryLabelColor).setFill()
      NSBezierPath(ovalIn: rect).fill()
    }
    let symbol = accessory == .add ? "plus" : "checkmark"
    let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
      .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    guard
      let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    else { return }
    let size = image.size
    image.draw(
      in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }

  /// Draws above the highlight; all layout lives in the row.
  private final class Canvas: NSView {
    weak var owner: RunMenuRowView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { owner?.drawContent() }
  }

  private static let truncating: NSParagraphStyle = {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    return style
  }()

  private static func aspectFit(_ size: NSSize, in box: CGFloat) -> NSSize {
    guard size.width > 0, size.height > 0 else { return NSSize(width: box, height: box) }
    let scale = min(1, box / max(size.width, size.height))
    return NSSize(width: size.width * scale, height: size.height * scale)
  }

  // MARK: Accessibility

  // A view-backed item's AXPress lands on the view, not the item's action,
  // so the row answers it itself; the add accessory is a custom action.
  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .menuItem }
  override func accessibilityLabel() -> String? {
    [content.title, content.subtitle].compactMap { $0 }.joined(separator: ", ")
  }
  override func accessibilityValue() -> Any? {
    content.accessory == .added ? "Added" : nil
  }

  override func accessibilityPerformPress() -> Bool {
    perform(onRun)
    return true
  }

  override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
    guard content.accessory == .add, onAdd != nil else { return nil }
    return [
      NSAccessibilityCustomAction(name: "Add to Project Commands") { [weak self] in
        self?.perform(self?.onAdd)
        return true
      }
    ]
  }

  // MARK: Events

  // The highlighted row is the menu's first responder, so Return reaches it
  // here; AppKit never sends a view-backed item's action for Return.
  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    if [36, 76].contains(event.keyCode) {  // Return, keypad Enter
      perform(onRun)
    } else {
      super.keyDown(with: event)
    }
  }

  /// Menu windows don't deliver mouse-moved events by default; the add
  /// accessory's hover state needs them.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.acceptsMouseMovedEvents = true
  }

  override func mouseMoved(with event: NSEvent) {
    isAccessoryHovered = content.accessory == .add && accessoryRect.contains(convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with event: NSEvent) {
    isAccessoryHovered = false
  }

  override func mouseUp(with event: NSEvent) {
    guard enclosingMenuItem?.isEnabled ?? true else { return }
    let point = convert(event.locationInWindow, from: nil)
    perform((content.accessory == .add && accessoryRect.contains(point)) ? onAdd : onRun)
  }

  /// Closes the whole menu (submenus included), then acts — after the menu
  /// has gone away, like a stock item's action.
  private func perform(_ action: (() -> Void)?) {
    var root = enclosingMenuItem?.menu
    while let parent = root?.supermenu { root = parent }
    root?.cancelTracking()
    DispatchQueue.main.async { action?() }
  }
}
