import CodansCore
import GhosttyKit

/// How a remote key (`terminal.sendEvents`) that libghostty matches as a
/// binding is handled.
///
/// libghostty's C API says whether a key is bound but not what the binding
/// does, and many default bindings are terminal input a remote keyboard
/// needs: `alt+←` types `esc:b`, `shift+←` adjusts a selection only when
/// one exists and otherwise falls through to the pane. Refusing every bound
/// key would make those unreachable from a phone. So only ⌘ chords — the
/// Mac app's own shortcuts — are refused up front; any other bound key is
/// pressed with a `RemoteKeyGuard` installed, which swallows whatever app
/// or window action the binding raises (next tab, new split, quit, …) and
/// reports the key as rejected instead.
nonisolated enum RemoteKeyBinding {
  enum Decision: Equatable, Sendable {
    /// Not a binding: encode it for the pane.
    case encode
    /// A ⌘ binding: never pressed.
    case reject
    /// A binding without ⌘: pressed under a `RemoteKeyGuard`.
    case performGuarded
  }

  static func decide(isBinding: Bool, mods: KeyEventSpec.Mods) -> Decision {
    guard isBinding else { return .encode }
    return mods.contains(.super) ? .reject : .performGuarded
  }

  /// Actions that only report terminal state (redraws, titles, the mouse
  /// cursor, the bell). They can fire while any key is processed, so a
  /// guard lets them through rather than blaming the key for them.
  /// Everything else a binding raises changes the Mac's windows, tabs,
  /// splits or app, and is suppressed.
  static func passesGuard(_ tag: ghostty_action_tag_e) -> Bool {
    switch tag {
    case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_MOUSE_SHAPE, GHOSTTY_ACTION_MOUSE_VISIBILITY,
      GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_PWD,
      GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_SCROLLBAR,
      GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_PROGRESS_REPORT, GHOSTTY_ACTION_COMMAND_FINISHED,
      GHOSTTY_ACTION_RING_BELL, GHOSTTY_ACTION_SECURE_INPUT:
      return true
    default:
      return false
    }
  }
}

/// Installed on `GhosttyRuntime` for the duration of one guarded remote
/// key press. libghostty performs a binding synchronously inside
/// `ghostty_surface_key` on the calling (main) thread, so every action the
/// runtime receives on the main thread while a guard is installed came from
/// that key. The guard also refuses clipboard reads for its pane, so a
/// user-configured non-⌘ paste binding cannot hand the Mac's clipboard to
/// a remote device.
@MainActor
final class RemoteKeyGuard {
  let paneID: PaneID
  /// Whether the key raised an action the guard swallowed.
  private(set) var suppressed = false

  init(paneID: PaneID) {
    self.paneID = paneID
  }

  /// True when the runtime must drop `tag` instead of applying it. A
  /// surface action for another pane is not this key's doing.
  func shouldSuppress(_ tag: ghostty_action_tag_e, surfacePaneID: PaneID?) -> Bool {
    if let surfacePaneID, surfacePaneID != paneID { return false }
    guard !RemoteKeyBinding.passesGuard(tag) else { return false }
    suppressed = true
    return true
  }

  /// True when a clipboard read for `readerPaneID` must be refused.
  func shouldRefuseClipboardRead(for readerPaneID: PaneID) -> Bool {
    guard readerPaneID == paneID else { return false }
    suppressed = true
    return true
  }
}
