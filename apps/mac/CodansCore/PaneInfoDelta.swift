import Foundation

/// Single-field mutation to a pane's informational state (title, pwd,
/// mouse shape, search status, etc.). Emitted by the Runtime decoder as
/// the typed Swift translation of a libghostty info-family action; applied
/// to `PaneSurface.info` and also fanned out on `TerminalEvent.paneInfoChanged`
/// so UI features (tab chrome, notifications, progress overlays) can react.
///
/// Raw C enum values (`mouseShape`, `promptTitle`, `secureInput`, `progress.state`)
/// are kept as `UInt32` rather than remapped to Swift enums: the decoder
/// is the single translation seam, and forwarding the raw tag keeps this
/// enum stable when libghostty adds new variants.
public nonisolated enum PaneInfoDelta: Sendable, Equatable {
  case title(String?)
  case tabTitle(String?)
  case promptTitle(UInt32)
  case pwd(String?)
  case mouseShape(UInt32)
  case mouseVisible(Bool)
  case mouseOverLink(String?)
  case colorChange(kind: Int32, r: UInt8, g: UInt8, b: UInt8)
  case rendererHealthy(Bool)
  case cellSize(width: UInt32, height: UInt32)
  case sizeLimit(minWidth: UInt32, minHeight: UInt32, maxWidth: UInt32, maxHeight: UInt32)
  case initialSize(width: UInt32, height: UInt32)
  case resetWindowSize
  case scrollbar(total: Int, offset: Int, length: Int)
  case secureInput(UInt32)
  case keySequence(active: Bool, trigger: UInt32)
  case keyTable(name: String?, depth: Int)
  case readonly(Bool)
  case quitTimer(UInt32)
  case floatWindow(Bool)
  case searchStarted(needle: String)
  case searchEnded
  case searchTotal(Int)
  case searchSelected(Int)
  case progress(state: UInt32, value: Int?)
  case bellRang
  case desktopNotification(title: String, body: String)
  case commandFinished(exitCode: Int32, duration: UInt64)
  case childExited(code: Int32)
}
