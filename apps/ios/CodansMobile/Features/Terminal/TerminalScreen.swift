import SwiftUI
import UIKit

/// The live terminal as a SwiftUI view: the pane's fixed grid, fitted to
/// the width by default, pinch-zoomable, following the bottom of the
/// output until the user scrolls away.
struct TerminalScreen: UIViewRepresentable {
  let model: TerminalScreenModel
  var onTap: () -> Void = {}

  func makeUIView(context: Context) -> TerminalHostView {
    TerminalHostView(model: model)
  }

  func updateUIView(_ host: TerminalHostView, context: Context) {
    host.onTap = onTap
    if host.model !== model { host.attach(model) }
  }

  static func dismantleUIView(_ host: TerminalHostView, coordinator: ()) {
    host.detach()
  }
}

/// Hosts a `MirrorTerminalView` in a zooming scroll view. The terminal
/// sits in a plain container that is the zooming view, so the zoom is a
/// transform and never touches the terminal's bounds (its grid).
final class TerminalHostView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
  private(set) var model: TerminalScreenModel
  var onTap: () -> Void = {}

  private let scrollView = UIScrollView()
  private let container = UIView()
  /// True until the user zooms: the fit follows rotations and splits.
  private var fitsWidth = true
  /// Whether the zoomed viewport keeps to the grid's bottom rows.
  private var viewportFollowsBottom = true
  private var scrollbackFollowsBottom = true

  /// Bitmap scale ceiling: a 200-column grid rasterized at 3× screen scale
  /// times a deep zoom would need a backing store of tens of megapixels.
  private static let maxContentScale: CGFloat = 6

  init(model: TerminalScreenModel) {
    self.model = model
    super.init(frame: .zero)
    backgroundColor = MirrorTerminalView.background
    scrollView.delegate = self
    scrollView.bouncesZoom = true
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.backgroundColor = MirrorTerminalView.background
    addSubview(scrollView)
    scrollView.addSubview(container)
    let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
    tap.delegate = self
    tap.cancelsTouchesInView = false
    addGestureRecognizer(tap)
    attach(model)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func attach(_ model: TerminalScreenModel) {
    if self.model.host === self { self.model.host = nil }
    self.model = model
    model.host = self
    let terminal = model.view
    terminal.removeFromSuperview()
    container.addSubview(terminal)
    terminal.onFollowingBottomChange = { [weak self] following in
      self?.scrollbackFollowsBottom = following
      self?.publishFollowing()
    }
    fitsWidth = true
    gridDidChange()
  }

  func detach() {
    if model.host === self { model.host = nil }
    model.view.onFollowingBottomChange = nil
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    guard scrollView.frame != bounds else { return }
    scrollView.frame = bounds
    refit()
  }

  /// The grid changed size: resize the container to it and refit.
  func gridDidChange() {
    let terminal = model.view
    let size = terminal.bounds.size
    let zoom = scrollView.zoomScale
    scrollView.zoomScale = 1
    container.frame = CGRect(origin: .zero, size: size)
    terminal.center = CGPoint(x: size.width / 2, y: size.height / 2)
    scrollView.contentSize = size
    scrollView.zoomScale = zoom
    refit()
  }

  private var fitScale: CGFloat {
    let width = model.view.gridPointSize.width
    guard width > 0, bounds.width > 0 else { return 1 }
    return bounds.width / width
  }

  private func refit() {
    guard bounds.width > 0 else { return }
    let fit = fitScale
    scrollView.minimumZoomScale = min(fit, 1)
    scrollView.maximumZoomScale = max(fit * 4, 3)
    if fitsWidth, abs(scrollView.zoomScale - fit) > 0.001 {
      scrollView.zoomScale = fit
      updateContentScale()
    }
    if viewportFollowsBottom { scrollViewportToBottom(animated: false) }
  }

  private var viewportBottomOffset: CGFloat {
    max(0, scrollView.contentSize.height - scrollView.bounds.height)
  }

  private func scrollViewportToBottom(animated: Bool) {
    let offset = CGPoint(x: scrollView.contentOffset.x, y: viewportBottomOffset)
    guard abs(offset.y - scrollView.contentOffset.y) > 0.5 else { return }
    scrollView.setContentOffset(offset, animated: animated)
  }

  private func updateContentScale() {
    let screenScale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
    model.view.contentScaleFactor = min(max(screenScale, 1) * max(scrollView.zoomScale, 1), Self.maxContentScale)
    model.view.setNeedsDisplay()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { updateContentScale() }
  }

  // MARK: - Commands

  func zoom(by factor: CGFloat) {
    let target = min(max(scrollView.zoomScale * factor, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
    fitsWidth = abs(target - fitScale) < 0.01
    scrollView.setZoomScale(target, animated: true)
  }

  func jumpToBottom() {
    viewportFollowsBottom = true
    scrollViewportToBottom(animated: true)
    model.view.scrollToLiveBottom()
    scrollbackFollowsBottom = true
    publishFollowing()
  }

  private func publishFollowing() {
    let following = viewportFollowsBottom && scrollbackFollowsBottom
    if model.isFollowingBottom != following { model.isFollowingBottom = following }
  }

  @objc private func tapped() {
    onTap()
  }

  // MARK: - UIScrollViewDelegate

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    if scrollView.isZooming || scrollView.isZoomBouncing {
      fitsWidth = abs(scrollView.zoomScale - fitScale) < 0.01
    }
  }

  func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
    updateContentScale()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    // Only the user's scrolling changes whether the viewport follows;
    // programmatic moves (refit, jump) keep the current choice.
    guard scrollView.isTracking || scrollView.isDecelerating else { return }
    viewportFollowsBottom = scrollView.contentOffset.y >= viewportBottomOffset - 2
    publishFollowing()
  }

  // MARK: - UIGestureRecognizerDelegate

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool { true }
}
