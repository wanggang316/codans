import SwiftTerm
import UIKit

/// A render-only SwiftTerm view whose grid is the Mac pane's, never one
/// derived from the view's size.
///
/// SwiftTerm computes its grid in `layoutSubviews` as
/// `Int(bounds.width / cellWidth)` × `Int(bounds.height / cellHeight)`, so
/// the bounds are pinned to exactly `cols × cellWidth` by
/// `rows × cellHeight` plus a quarter-cell slack (float truncation would
/// otherwise lose a column at some sizes). Zoom is a transform on an outer
/// container: transforms never change `bounds`, so zooming never
/// re-derives the grid. `TerminalView.resize(cols:rows:)` and font changes
/// are off limits while streaming — both soft-reset the terminal, dropping
/// the modes and scroll region the Mac's bytes set up.
final class MirrorTerminalView: TerminalView {
  private(set) var gridCols: Int
  private(set) var gridRows: Int
  /// Called when the scrollback position moves: `true` while the view
  /// shows the live bottom of the buffer.
  var onFollowingBottomChange: ((Bool) -> Void)?
  private(set) var isFollowingBottom = true
  /// UIScrollView adjusts `contentOffset` inside `super.init`, before the
  /// terminal exists.
  private var isReady = false

  /// Fraction of a cell added to the pinned bounds.
  private static let slack: CGFloat = 0.25
  static let scrollbackRows = 2000

  init(cols: Int, rows: Int, font: UIFont) {
    gridCols = cols
    gridRows = rows
    // A zero frame keeps SwiftTerm on the options' grid instead of one
    // derived from a frame.
    super.init(
      frame: .zero, font: font,
      options: TerminalOptions(cols: cols, rows: rows, scrollback: Self.scrollbackRows))
    inputAccessoryView = nil
    inputView = nil
    // Taps would otherwise become mouse reports, which `send` drops anyway;
    // this keeps them from being consumed as clicks at all.
    allowMouseReporting = false
    isScrollEnabled = true
    showsHorizontalScrollIndicator = false
    applyPalette()
    isReady = true
    setGrid(cols: cols, rows: rows)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  // MARK: - Render only

  override var canBecomeFirstResponder: Bool { false }
  override var canBecomeFocused: Bool { false }

  /// Replies to queries in the stream (DA, CPR, DSR) and mouse reports.
  /// The Mac's surface already answers the queries; answering again would
  /// type the replies into the shell a second time.
  override func send(source: Terminal, data: ArraySlice<UInt8>) {}

  override var contentOffset: CGPoint {
    didSet { updateFollowingBottom() }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateFollowingBottom()
  }

  private func updateFollowingBottom() {
    guard isReady else { return }
    let bottom = max(0, contentSize.height - bounds.height)
    let following = contentOffset.y >= bottom - cellSize.height / 2
    guard following != isFollowingBottom else { return }
    isFollowingBottom = following
    onFollowingBottomChange?(following)
  }

  /// Scrolls the scrollback back to the live screen.
  func scrollToLiveBottom() {
    let bottom = max(0, contentSize.height - bounds.height)
    setContentOffset(CGPoint(x: 0, y: bottom), animated: true)
  }

  // MARK: - Fixed grid

  /// One cell in points. SwiftTerm's cell dimension is internal, but
  /// `getOptimalFrameSize()` is public and is exactly it times the grid.
  var cellSize: CGSize {
    let terminal = getTerminal()
    let optimal = getOptimalFrameSize().size
    guard terminal.cols > 0, terminal.rows > 0 else { return CGSize(width: 7, height: 14) }
    return CGSize(width: optimal.width / CGFloat(terminal.cols), height: optimal.height / CGFloat(terminal.rows))
  }

  /// The grid's drawn size in points, without the slack.
  var gridPointSize: CGSize {
    let cell = cellSize
    return CGSize(width: cell.width * CGFloat(gridCols), height: cell.height * CGFloat(gridRows))
  }

  /// Sets the grid by pinning `bounds`, never with
  /// `TerminalView.resize(cols:rows:)`, which also soft-resets.
  func setGrid(cols: Int, rows: Int) {
    gridCols = max(cols, 1)
    gridRows = max(rows, 1)
    let cell = cellSize
    let size = CGSize(
      width: cell.width * (CGFloat(gridCols) + Self.slack),
      height: cell.height * (CGFloat(gridRows) + Self.slack))
    // `bounds`, not `frame`: the frame is undefined under a zoom transform.
    bounds = CGRect(origin: bounds.origin, size: size)
    setNeedsLayout()
    layoutIfNeeded()
  }

  /// A blank screen at a new grid, as a stream `reset` asks for. The full
  /// reset (RIS) clears modes, scroll region, alternate screen and
  /// scrollback, so the snapshot bytes that follow start from nothing.
  func resetScreen(cols: Int, rows: Int) {
    feed(byteArray: Self.fullReset[...])
    setGrid(cols: cols, rows: rows)
  }

  /// `ESC c`, then clear the scrollback: RIS alone keeps SwiftTerm's
  /// scrollback lines.
  private static let fullReset: [UInt8] = Array("\u{1B}c\u{1B}[3J".utf8)

  // MARK: - Palette

  /// Always dark, whatever the app's appearance: agent TUIs pick their
  /// colours for a dark terminal, as on the Mac.
  static let background = UIColor(red: 0.075, green: 0.078, blue: 0.086, alpha: 1)

  private func applyPalette() {
    func color(_ hex: UInt32) -> SwiftTerm.Color {
      // SwiftTerm colour components are 16-bit.
      SwiftTerm.Color(
        red: UInt16((hex >> 16) & 0xFF) * 257,
        green: UInt16((hex >> 8) & 0xFF) * 257,
        blue: UInt16(hex & 0xFF) * 257)
    }
    let ansi: [UInt32] = [
      0x1D1F21, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xC8CCD4,
      0x5C6370, 0xFF7A85, 0xB5E08F, 0xFFD68A, 0x80C4FF, 0xDA9BEE, 0x7AD3DE, 0xF2F4F8,
    ]
    installColors(ansi.map(color))
    nativeBackgroundColor = Self.background
    nativeForegroundColor = UIColor(white: 0.88, alpha: 1)
    caretColor = UIColor(white: 0.92, alpha: 0.85)
    // SwiftTerm paints default-background cells from the layer.
    layer.backgroundColor = Self.background.cgColor
    backgroundColor = Self.background
  }
}
