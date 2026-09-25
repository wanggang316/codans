import AppKit
import CodansCore
import SwiftUI

/// What the chip row needs to know about the scroll viewport it lives in.
struct TabBarViewport {
  /// Width available to the chips inside the track.
  var width: CGFloat
  /// Current horizontal content offset of the scroll view.
  var scrollOffset: CGFloat
  /// Programmatic scrolling (stack clicks, revealing an added tab).
  var scroller: TabBarScroller?

  static let unbounded = TabBarViewport(width: 0, scrollOffset: 0, scroller: nil)
}

/// Binds to the row's underlying `NSScrollView`: publishes its live offset
/// and scrolls it directly, so programmatic scrolls use AppKit's own
/// clip-view animation — the mechanism the system tab bar uses. SwiftUI's
/// `ScrollViewReader` can only scroll to a view id, and SwiftUI geometry
/// does not observe scrolls AppKit performs, so the offset is read from the
/// clip view's bounds notifications instead.
@MainActor
@Observable
final class TabBarScroller: NSObject {
  private(set) var offset: CGFloat = 0

  @ObservationIgnored
  weak var scrollView: NSScrollView? {
    didSet {
      guard scrollView !== oldValue else { return }
      if let old = oldValue?.contentView {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old)
      }
      guard let clip = scrollView?.contentView else { return }
      clip.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: clip)
      offset = clip.bounds.origin.x
      installWheelMonitor()
    }
  }

  /// Local monitor that turns a vertical wheel over the bar into horizontal
  /// scrolling, as the system tab bar does.
  @ObservationIgnored
  private nonisolated(unsafe) var wheelMonitor: Any?

  // Explicit deinit: this object is `@State`-owned inside a subtree that a
  // catalog mutation can tear down; the synthesized isolated deinit crashes
  // there. Selector-based observers unregister themselves on dealloc.
  deinit {
    if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
  }

  private func installWheelMonitor() {
    guard wheelMonitor == nil else { return }
    // Local monitors are called on the main thread; NSEvent is not
    // Sendable, so it crosses the isolation assertion through a local.
    wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      nonisolated(unsafe) var result: NSEvent? = event
      MainActor.assumeIsolated {
        guard let self, let event = result else { return }
        result = self.redirectVerticalWheel(event)
      }
      return result
    }
  }

  /// Scrolls the bar horizontally for a mostly-vertical wheel over it and
  /// consumes the event, as the system tab bar does. Line-based wheels move
  /// 10 pt per line (measured on the system bar); precise deltas (trackpad,
  /// including its momentum phase) move 1:1.
  private func redirectVerticalWheel(_ event: NSEvent) -> NSEvent? {
    guard let scrollView, event.window === scrollView.window,
      abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
      scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil))
    else { return event }
    let clip = scrollView.contentView
    let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
    let maxX = max(0, (scrollView.documentView?.frame.width ?? 0) - clip.bounds.width)
    let x = min(max(clip.bounds.origin.x - delta, 0), maxX)
    clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
    scrollView.reflectScrolledClipView(clip)
    return nil
  }

  @objc private func clipBoundsChanged(_ note: Notification) {
    guard let clip = note.object as? NSClipView else { return }
    let x = clip.bounds.origin.x
    if x != offset { offset = x }
  }

  func scroll(to offset: CGFloat, animated: Bool) {
    guard let scrollView else { return }
    let clip = scrollView.contentView
    let target = NSPoint(x: offset, y: clip.bounds.origin.y)
    guard abs(target.x - clip.bounds.origin.x) > 0.5 else { return }
    if animated {
      // Measured on the system bar: 0.25 s, ease-out cubic.
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
        clip.animator().setBoundsOrigin(target)
      } completionHandler: {
        MainActor.assumeIsolated { scrollView.reflectScrolledClipView(clip) }
      }
    } else {
      clip.scroll(to: target)
      scrollView.reflectScrolledClipView(clip)
    }
  }
}

/// Horizontal scroll host for the chip row. Sits between `TabBarView` and
/// `TabBarRowView`: the container owns the track and the scroll view, the
/// row owns chip layout (including the overflow stacking, which replaces
/// edge fades — the system bar has none).
///
/// - Scrollbar hidden so the bar reads as a continuous ribbon.
/// - Draws the recessed capsule track behind the row, with the scrolling
///   content inset `trackContentInset` on every side as in the system tab
///   bar.
/// - Selecting a tab never scrolls (system behaviour); the row asks the
///   scroller to move only for stack clicks and newly added tabs.
struct TabBarOverflowScroll<Content: View>: View {
  @ViewBuilder let content: (_ viewport: TabBarViewport) -> Content

  @State private var scroller = TabBarScroller()

  var body: some View {
    GeometryReader { container in
      ScrollView(.horizontal, showsIndicators: false) {
        content(
          TabBarViewport(width: container.size.width, scrollOffset: scroller.offset, scroller: scroller)
        )
      }
      // Outside the scroll content on purpose: an AppKit view inside the
      // content stops SwiftUI from drawing the chips.
      .background(ScrollViewLocator(scroller: scroller))
      // Clip at the track's outer capsule instead of the inset scroll
      // bounds, so the selected capsule's drop shadow shows in the inset
      // margin as it does in the system bar.
      .scrollClipDisabled()
    }
    .padding(TabBarMetrics.trackContentInset)
    .background(Capsule().fill(TabBarColors.trackBackground))
    .clipShape(Capsule())
  }
}

/// Transparent probe laid out behind the `ScrollView`; finds the AppKit
/// `NSScrollView` backing it (the one occupying the same rect) and hands it
/// to the scroller.
private struct ScrollViewLocator: NSViewRepresentable {
  let scroller: TabBarScroller

  func makeNSView(context: Context) -> Probe { Probe(scroller: scroller) }
  func updateNSView(_ nsView: Probe, context: Context) {
    nsView.scroller = scroller
    nsView.locate()
  }

  final class Probe: NSView {
    var scroller: TabBarScroller

    init(scroller: TabBarScroller) {
      self.scroller = scroller
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {}

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      locate()
    }

    override func layout() {
      super.layout()
      locate()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func locate() {
      guard let root = window?.contentView, bounds.width > 0,
        scroller.scrollView?.window !== window || scroller.scrollView == nil
      else { return }
      let target = convert(bounds, to: nil)
      scroller.scrollView = Self.scrollView(in: root, matching: target)
    }

    private static func scrollView(in view: NSView, matching rect: NSRect) -> NSScrollView? {
      if let scroll = view as? NSScrollView {
        let frame = scroll.convert(scroll.bounds, to: nil)
        if abs(frame.minX - rect.minX) <= 1, abs(frame.minY - rect.minY) <= 1,
          abs(frame.width - rect.width) <= 1, abs(frame.height - rect.height) <= 1
        {
          return scroll
        }
      }
      for sub in view.subviews {
        if let found = scrollView(in: sub, matching: rect) { return found }
      }
      return nil
    }
  }
}
