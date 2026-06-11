import AppKit
import SwiftUI

/// NSViewRepresentable bridge that fires `onMiddleClick` when the tertiary
/// (middle) mouse button is released over the view. Middle-click is the
/// canonical macOS "close tab" pointer shortcut; SwiftUI does not surface
/// it natively, so the chip overlays this thin AppKit layer.
///
/// Attached as a SwiftUI `.overlay` so the chip's hover / press behavior
/// is preserved — left clicks pass through to the underlying
/// `TabChipView` via the AppKit hit-test override.
struct TabChipMiddleClickView: NSViewRepresentable {
  let onMiddleClick: () -> Void

  func makeNSView(context: Context) -> MiddleClickCatcher {
    let view = MiddleClickCatcher()
    view.onMiddleClick = onMiddleClick
    return view
  }

  func updateNSView(_ nsView: MiddleClickCatcher, context: Context) {
    nsView.onMiddleClick = onMiddleClick
  }
}

/// AppKit layer that only claims hits coming from the tertiary mouse
/// button. Left / right clicks fall through to the SwiftUI content
/// underneath because `hitTest` returns `nil` for everything else.
final class MiddleClickCatcher: NSView {
  var onMiddleClick: (() -> Void)?

  /// Forward the event back to AppKit for anything except the middle
  /// button so our catcher never swallows primary clicks. Middle-button
  /// hits reach `otherMouseUp` via the default responder chain.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let event = NSApp.currentEvent else { return nil }
    switch event.type {
    case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
      return super.hitTest(point)
    default:
      return nil
    }
  }

  override func otherMouseUp(with event: NSEvent) {
    // `buttonNumber == 2` is the tertiary button (middle). `0` = primary,
    // `1` = secondary; anything else (e.g. thumb buttons) falls through.
    if event.buttonNumber == 2 {
      onMiddleClick?()
    } else {
      super.otherMouseUp(with: event)
    }
  }
}
