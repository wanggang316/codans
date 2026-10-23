import AppKit
import SwiftUI

/// Draws the system scroll edge effect of the window toolbar over the
/// content behind it. AppKit gives an `NSScrollView` that lies under the
/// toolbar a scroll pocket the height of its top safe area, and the pocket
/// blurs what is behind it. This view is an empty, transparent scroll view
/// laid over the Panes: the pocket covers the toolbar plus `extraTopInset`
/// below it, so the terminals under the toolbar and the top tab strips show
/// through the same effect as a scroll view under a Safari tab bar.
///
/// It never takes events. Out from under the toolbar AppKit draws no pocket,
/// so the view then shows nothing. A hidden toolbar background
/// (`.toolbarBackground(.hidden)`) hides the effect too.
struct ScrollEdgeEffectView: NSViewRepresentable {
  /// Height of the band below the toolbar that the effect also covers.
  let extraTopInset: CGFloat

  func makeNSView(context: Context) -> ScrollEdgeEffectHostView {
    ScrollEdgeEffectHostView()
  }

  func updateNSView(_ nsView: ScrollEdgeEffectHostView, context: Context) {
    nsView.extraTopInset = extraTopInset
  }
}

final class ScrollEdgeEffectHostView: NSView {
  private let scrollView = NSScrollView()
  private let documentView = NSView()

  var extraTopInset: CGFloat = 0 {
    didSet {
      guard extraTopInset != oldValue else { return }
      additionalSafeAreaInsets = NSEdgeInsets(top: extraTopInset, left: 0, bottom: 0, right: 0)
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.documentView = documentView
    addSubview(scrollView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func layout() {
    super.layout()
    scrollView.frame = bounds
    // A document the size of the clip view: there is nothing to scroll,
    // the pocket only blurs what lies behind it.
    documentView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
