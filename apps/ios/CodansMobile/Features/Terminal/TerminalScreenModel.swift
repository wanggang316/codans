import Foundation
import UIKit

/// The emulator behind one pane's live terminal, owned outside SwiftUI's
/// view lifetime so the screen survives the view being rebuilt.
///
/// `TerminalStreamFeature` drives it synchronously from its reducer, in
/// frame order: bytes cannot be kept in reducer state (a busy agent streams
/// megabytes), and applying them from separate effects would not keep
/// their order. It compares by identity so it can live in `State`. The
/// few properties views read (following the bottom) are observable.
@MainActor
@Observable
final class TerminalScreenModel {
  /// What the reducer asked of the screen, kept when `isRecording` so tests
  /// can assert on it without rendering.
  enum Command: Equatable {
    case reset(cols: Int, rows: Int)
    case feed(Data)
    case resize(cols: Int, rows: Int)
  }

  @ObservationIgnored private(set) var commands: [Command] = []
  @ObservationIgnored private let isRecording: Bool
  @ObservationIgnored private(set) var cols = 80
  @ObservationIgnored private(set) var rows = 24
  /// Whether both the scrollback and the zoomed viewport show the live
  /// bottom. False once the user scrolls away; the screen then offers a
  /// jump back.
  var isFollowingBottom = true

  /// Created on first use: a model the tests drive never builds UIKit.
  @ObservationIgnored private var terminalView: MirrorTerminalView?
  /// The scroll view hosting `view`, for zoom and jump commands.
  @ObservationIgnored weak var host: TerminalHostView?

  init(isRecording: Bool = false) {
    self.isRecording = isRecording
  }

  // Explicit: a synthesized isolated deinit on an observable has crashed
  // on release.
  deinit {}

  /// The font the grid is drawn with. Size only sets the unzoomed cell;
  /// what the user sees comes from the zoom.
  /// It is the Mac's terminal font, bundled with the app; the system
  /// monospaced font is only a fallback and has no Nerd Font glyphs.
  static let font =
    UIFont(name: "JetBrainsMonoNF-Regular", size: 13)
    ?? UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

  var view: MirrorTerminalView {
    if let terminalView { return terminalView }
    let view = MirrorTerminalView(cols: cols, rows: rows, font: Self.font)
    terminalView = view
    return view
  }

  var hasView: Bool { terminalView != nil }

  /// The pane's key modes as this device's emulator tracks them, for
  /// encoding keys typed through a terminal seat.
  var keyModes: TerminalKeyEncoder.Modes {
    guard let terminalView else { return TerminalKeyEncoder.Modes() }
    let terminal = terminalView.getTerminal()
    return TerminalKeyEncoder.Modes(
      applicationCursor: terminal.applicationCursor, bracketedPaste: terminal.bracketedPasteMode)
  }

  /// Told the grid that fills the screen at the device's text size, when
  /// it changes: the size of this device's terminal seat.
  @ObservationIgnored var onSeatSizeChange: ((Int, Int) -> Void)?
  @ObservationIgnored private var lastSeatSize: (cols: Int, rows: Int)?

  func reportSeatSize(cols: Int, rows: Int) {
    guard cols > 0, rows > 0, lastSeatSize.map({ $0 != (cols, rows) }) ?? true else { return }
    lastSeatSize = (cols, rows)
    onSeatSizeChange?(cols, rows)
  }

  /// Sends the last reported seat size again, to a handler set after it.
  func replaySeatSize() {
    guard let lastSeatSize else { return }
    onSeatSizeChange?(lastSeatSize.cols, lastSeatSize.rows)
  }

  func reset(cols: Int, rows: Int) {
    if isRecording { commands.append(.reset(cols: cols, rows: rows)) }
    self.cols = cols
    self.rows = rows
    guard !isRecording else { return }
    view.resetScreen(cols: cols, rows: rows)
    host?.gridDidChange()
  }

  func feed(_ data: Data) {
    if isRecording {
      commands.append(.feed(data))
      return
    }
    view.feed(byteArray: [UInt8](data)[...])
    host?.outputDidArrive()
  }

  func resize(cols: Int, rows: Int) {
    if isRecording { commands.append(.resize(cols: cols, rows: rows)) }
    self.cols = cols
    self.rows = rows
    guard !isRecording else { return }
    view.setGrid(cols: cols, rows: rows)
    host?.gridDidChange()
  }
}

extension TerminalScreenModel {
  /// Scales the zoom by `factor` (⌘+ / ⌘-); the font never changes.
  func zoom(by factor: CGFloat) {
    host?.zoom(by: factor)
  }

  /// Back to the live bottom of both the zoomed viewport and scrollback.
  func jumpToBottom() {
    host?.jumpToBottom()
  }
}

extension TerminalScreenModel: Equatable {
  static func == (lhs: TerminalScreenModel, rhs: TerminalScreenModel) -> Bool { lhs === rhs }
}
