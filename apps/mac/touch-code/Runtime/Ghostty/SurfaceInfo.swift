import Foundation
import GhosttyKit
import TouchCodeCore

/// Most recent color-change report emitted by libghostty for a surface.
/// Kept flat (not a tuple) so `@Observable`'s per-property change tracking
/// can notify observers when any single channel updates.
struct ColorChange: Equatable, Sendable {
  var kind: Int32
  var r: UInt8
  var g: UInt8
  var b: UInt8
}

/// Observable, per-surface informational state maintained from the
/// `PaneInfoDelta` stream. Every field corresponds to one or more
/// libghostty info-family actions decoded by `GhosttyActionDecoder` and
/// applied via `PaneSurface.apply(_:)`.
///
/// All composite payloads (cell size, size limits, scrollbar, key sequence,
/// key table) are flattened into individual stored properties — `@Observable`
/// tracks reads/writes per property, so tuples would hide mutations behind
/// a single KeyPath and defeat fine-grained SwiftUI updates.
///
/// State here is ephemeral: not persisted, reset on relaunch. The catalog
/// tracks stable hierarchy only.
@MainActor
@Observable
final class SurfaceInfo {
  // MARK: - Titles / prompt / pwd

  var title: String?
  var tabTitle: String?
  /// Raw `ghostty_action_prompt_title_e` tag forwarded from libghostty;
  /// kept as UInt32 to avoid pinning this type to ghostty's C enum layout.
  var promptTitle: UInt32 = 0
  var pwd: String?

  // MARK: - Mouse

  var mouseShape: UInt32 = 0
  var mouseVisible: Bool = true
  var mouseOverLink: String?

  // MARK: - Renderer / color

  var rendererHealthy: Bool = true
  /// Latest color-change report; nil until libghostty reports one.
  var colorChange: ColorChange?

  // MARK: - Geometry

  var cellWidth: UInt32 = 0
  var cellHeight: UInt32 = 0
  var sizeLimitMinWidth: UInt32 = 0
  var sizeLimitMinHeight: UInt32 = 0
  var sizeLimitMaxWidth: UInt32 = 0
  var sizeLimitMaxHeight: UInt32 = 0
  var initialWidth: UInt32 = 0
  var initialHeight: UInt32 = 0

  // MARK: - Scrollbar

  var scrollbarTotal: Int = 0
  var scrollbarOffset: Int = 0
  var scrollbarLength: Int = 0

  // MARK: - Input modes

  var secureInput: UInt32 = 0
  var keySequenceActive: Bool = false
  var keySequenceTrigger: UInt32 = 0
  var keyTableName: String?
  var keyTableDepth: Int = 0
  var readonly: Bool = false

  // MARK: - Window state

  var quitTimer: UInt32 = 0
  var floatWindow: Bool = false

  // MARK: - Search

  /// Populated by `.searchStarted`; cleared by `.searchEnded`.
  var searchNeedle: String?
  var searchTotal: Int?
  var searchSelected: Int?

  // MARK: - Progress

  var progressState: UInt32 = 0
  /// Nil when libghostty reports an indeterminate value (sentinel -1).
  var progressValue: Int?

  /// `true` when libghostty's last OSC 9;4 report leaves the surface in
  /// any non-`REMOVE` state — i.e. a tracked operation is in flight,
  /// paused at the finish line, or finished with an error worth flagging.
  /// The single predicate keeps downstream "is this pane busy?" logic
  /// consistent across consumers.
  var isProgressBusy: Bool {
    progressState != GHOSTTY_PROGRESS_STATE_REMOVE.rawValue
  }

  // MARK: - Bell / notification / lifecycle

  /// Monotonic counter — each `.bellRang` increments so consumers can
  /// detect transitions without persisting a timestamp.
  var bellCount: Int = 0
  var lastNotificationTitle: String?
  var lastNotificationBody: String?
  var lastCommandExitCode: Int32?
  var lastCommandDuration: UInt64?
  var lastChildExitCode: Int32?

  init() {}

  // Explicit empty deinit on a MainActor @Observable class to opt out of
  // the implicitly-synthesized isolated deinit. When PaneSurface (whose
  // deinit was made nonisolated by 2bbee60) releases its `info`, the
  // implicit isolated deinit on this class would hop via
  // `swift_task_deinitOnExecutorMainActorBackDeploy` and double-free a
  // TaskLocal scope along the cascade, tripping libmalloc. All stored
  // properties here are value types or plain optionals; no main-actor
  // coordination is needed for release.
  deinit {}
}
