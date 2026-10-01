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
///
/// The grid is the Mac pane's, often far wider than a phone. Fitting its
/// width would shrink the text to a few points, so the default is a
/// readable text size (the user's last pinch, remembered): the grid is
/// shown whole only when that is at least as large, and otherwise pans,
/// with the viewport following the cursor while it follows the output.
final class TerminalHostView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
  private(set) var model: TerminalScreenModel
  var onTap: () -> Void = {}

  private let scrollView = UIScrollView()
  private let container = UIView()
  /// Whether the zoomed viewport keeps to the grid's bottom rows.
  private var viewportFollowsBottom = true
  private var scrollbackFollowsBottom = true
  /// Whether the viewport follows the cursor sideways; off once the user
  /// pans sideways, back on with a jump to the bottom.
  private var viewportFollowsCursor = true
  private var isCursorFollowQueued = false

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
    scrollView.zoomScale = 1
    container.frame = CGRect(origin: .zero, size: size)
    terminal.center = CGPoint(x: size.width / 2, y: size.height / 2)
    scrollView.contentSize = size
    refit()
  }

  /// The zoom that shows the whole grid, capped so a tiny grid is not
  /// blown up past a comfortable size.
  private var overviewScale: CGFloat {
    let grid = model.view.gridPointSize
    guard grid.width > 0, grid.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
    return min(bounds.width / grid.width, bounds.height / grid.height, TerminalTextSize.maximum / TerminalTextSize.base)
  }

  /// The zoom that draws text at the user's size.
  private var readableScale: CGFloat {
    TerminalTextSize.preferred(for: traitCollection.horizontalSizeClass) / TerminalTextSize.base
  }

  /// Readable, or the whole grid when that is at least as large.
  private var defaultScale: CGFloat { max(readableScale, overviewScale) }

  private func refit() {
    guard bounds.width > 0 else { return }
    reportSeatSize()
    let target = defaultScale
    scrollView.minimumZoomScale = min(overviewScale, target)
    scrollView.maximumZoomScale = TerminalTextSize.maximum / TerminalTextSize.base
    if abs(scrollView.zoomScale - target) > 0.001 {
      scrollView.zoomScale = target
      updateContentScale()
    }
    alignToBottom()
    if viewportFollowsBottom { scrollViewportToBottom(animated: false) }
    followCursor()
  }

  /// The grid that fills this view at the device's text size: the size a
  /// terminal seat asks the pane to take.
  private func reportSeatSize() {
    let cell = model.view.cellSize
    let scale = readableScale
    guard cell.width > 0, cell.height > 0, scale > 0 else { return }
    let cols = Int((bounds.width / (cell.width * scale)).rounded(.down))
    let rows = Int((bounds.height / (cell.height * scale)).rounded(.down))
    model.reportSeatSize(cols: cols, rows: rows)
  }

  /// A grid shorter than the screen sits at its bottom, so the prompt and
  /// the newest output are next to the keys, with the spare room above.
  private func alignToBottom() {
    let spare = max(0, scrollView.bounds.height - scrollView.contentSize.height)
    guard abs(scrollView.contentInset.top - spare) > 0.5 else { return }
    scrollView.contentInset.top = spare
    scrollView.contentOffset.y = -spare
  }

  /// The offset that shows the grid's last row at the bottom; negative
  /// when a short grid sits in the bottom inset.
  private var viewportBottomOffset: CGFloat {
    max(-scrollView.contentInset.top, scrollView.contentSize.height - scrollView.bounds.height)
  }

  private func scrollViewportToBottom(animated: Bool) {
    let offset = CGPoint(x: scrollView.contentOffset.x, y: viewportBottomOffset)
    guard abs(offset.y - scrollView.contentOffset.y) > 0.5 else { return }
    scrollView.setContentOffset(offset, animated: animated)
  }

  /// Keeps the cursor's column in view while the viewport follows the
  /// output, preferring the left edge: a prompt or an agent's input box
  /// starts there.
  private func followCursor() {
    guard viewportFollowsBottom, viewportFollowsCursor, !scrollView.isTracking, !scrollView.isZooming else { return }
    let viewport = scrollView.bounds.width
    let content = scrollView.contentSize.width
    guard content > viewport + 1 else {
      if scrollView.contentOffset.x != 0 { scrollView.contentOffset.x = 0 }
      return
    }
    let cellWidth = model.view.cellSize.width * scrollView.zoomScale
    let cursorX = (CGFloat(model.view.getTerminal().getCursorLocation().x) + 0.5) * cellWidth
    let margin = cellWidth * 4
    let current = scrollView.contentOffset.x
    let target: CGFloat
    if cursorX < viewport - margin {
      target = 0
    } else if cursorX < current + margin || cursorX > current + viewport - margin {
      target = min(max(cursorX - viewport * 0.6, 0), content - viewport)
    } else {
      return
    }
    guard abs(target - current) > 0.5 else { return }
    scrollView.contentOffset.x = target
  }

  /// New output arrived: follow the cursor once per run loop turn, not per
  /// frame of bytes.
  func outputDidArrive() {
    guard !isCursorFollowQueued else { return }
    isCursorFollowQueued = true
    DispatchQueue.main.async { [weak self] in
      self?.isCursorFollowQueued = false
      self?.followCursor()
    }
  }

  /// Rasterizes at the size the grid is shown at, never finer: drawing a
  /// wide grid at full screen scale and shrinking it by the zoom would
  /// redraw several times the pixels on screen at every update.
  private func updateContentScale() {
    let screenScale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
    model.view.setRasterScale(min(max(screenScale * scrollView.zoomScale, 1), Self.maxContentScale))
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { updateContentScale() }
  }

  // MARK: - Commands

  func zoom(by factor: CGFloat) {
    let target = min(max(scrollView.zoomScale * factor, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
    scrollView.setZoomScale(target, animated: true)
    rememberTextSize(for: target)
    reportSeatSize()
  }

  func jumpToBottom() {
    viewportFollowsBottom = true
    viewportFollowsCursor = true
    scrollViewportToBottom(animated: true)
    model.view.scrollToLiveBottom()
    scrollbackFollowsBottom = true
    publishFollowing()
    followCursor()
  }

  private func publishFollowing() {
    let following = viewportFollowsBottom && scrollbackFollowsBottom
    if model.isFollowingBottom != following { model.isFollowingBottom = following }
  }

  /// A pinch sets the text size for every terminal, except one that ends
  /// on the whole-grid overview, which is a look, not a preference.
  private func rememberTextSize(for scale: CGFloat) {
    guard abs(scale - overviewScale) > 0.01 else { return }
    TerminalTextSize.setPreferred(scale * TerminalTextSize.base, for: traitCollection.horizontalSizeClass)
  }

  @objc private func tapped() {
    onTap()
  }

  // MARK: - UIScrollViewDelegate

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

  func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
    alignToBottom()
    updateContentScale()
    rememberTextSize(for: scale)
    // A new text size is a new seat grid.
    reportSeatSize()
    followCursor()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    // Only the user's scrolling changes what the viewport follows;
    // programmatic moves (refit, jump, cursor) keep the current choice.
    guard scrollView.isTracking || scrollView.isDecelerating else { return }
    viewportFollowsBottom = scrollView.contentOffset.y >= viewportBottomOffset - 2
    if scrollView.panGestureRecognizer.translation(in: scrollView).x != 0 { viewportFollowsCursor = false }
    publishFollowing()
  }

  // MARK: - UIGestureRecognizerDelegate

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool { true }
}

/// The terminal's text size on screen, in points: what a pinch sets and
/// what every terminal opens at. The grid is drawn with a 13 pt font and
/// zoomed to it.
enum TerminalTextSize {
  static let base: CGFloat = 13
  static let minimum: CGFloat = 6
  static let maximum: CGFloat = 26

  static func preferred(for sizeClass: UIUserInterfaceSizeClass) -> CGFloat {
    let stored = UserDefaults.standard.double(forKey: key(sizeClass))
    guard stored > 0 else { return sizeClass == .regular ? 12 : 11 }
    return min(max(CGFloat(stored), minimum), maximum)
  }

  static func setPreferred(_ size: CGFloat, for sizeClass: UIUserInterfaceSizeClass) {
    UserDefaults.standard.set(Double(min(max(size, minimum), maximum)), forKey: key(sizeClass))
  }

  /// Separate for compact and regular width: a size that suits an iPhone
  /// is small on an iPad.
  private static func key(_ sizeClass: UIUserInterfaceSizeClass) -> String {
    sizeClass == .regular ? "terminal.textSize.regular" : "terminal.textSize.compact"
  }
}
