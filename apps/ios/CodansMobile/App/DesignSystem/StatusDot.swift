import SwiftUI
import UIKit

/// A small state dot. With `pulses`, a soft ring breathes out of it: the
/// "working" signal, for agents and for a connection being made.
///
/// The ring is a Core Animation layer animation, run by the render server
/// without waking the app: a dot pulses on screen for as long as an agent
/// works, and a timeline-driven SwiftUI redraw at 30 fps kept the CPU busy
/// the whole time. It is also outside SwiftUI's transactions, so it cannot
/// leak into the layout of the toolbar that hosts it.
struct StatusDot: View {
  let color: Color
  var pulses = false
  var size: CGFloat = 8

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      if pulses, !reduceMotion {
        PulseRing(color: UIColor(color))
      }
      Circle().fill(color)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// The breathing ring: scale 1 → 2.4 while fading out, every 1.6 s.
private struct PulseRing: UIViewRepresentable {
  let color: UIColor

  func makeUIView(context: Context) -> PulseRingView { PulseRingView() }

  func updateUIView(_ view: PulseRingView, context: Context) {
    view.color = color
  }
}

private final class PulseRingView: UIView {
  private let ring = CAShapeLayer()
  private static let period: CFTimeInterval = 1.6

  var color: UIColor = .clear {
    didSet { ring.fillColor = color.resolvedColor(with: traitCollection).cgColor }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    layer.addSublayer(ring)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    ring.frame = bounds
    ring.path = UIBezierPath(ovalIn: bounds).cgPath
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    // Animations are removed when a layer leaves the window; add them back.
    ring.removeAllAnimations()
    guard window != nil else { return }
    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 1
    scale.toValue = 2.4
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0.45
    fade.toValue = 0
    let group = CAAnimationGroup()
    group.animations = [scale, fade]
    group.duration = Self.period
    group.repeatCount = .infinity
    group.timingFunction = CAMediaTimingFunction(name: .linear)
    ring.opacity = 0
    ring.add(group, forKey: "pulse")
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    ring.fillColor = color.resolvedColor(with: traitCollection).cgColor
  }
}
