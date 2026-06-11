import Foundation

/// Window / app-level intent decoded from a libghostty action. The Runtime
/// emits `TerminalEvent.windowActionRequested(request)`;
/// `WindowActionRouterFeature` dispatches to `WindowService`, `UpdatesClient`,
/// `AppLifecycleClient`, or `EditorClient` as appropriate.
///
/// `from:` carries the source pane's ID for intents that need to resolve
/// back to an `NSWindow`. The receiving router performs the mapping —
/// Runtime does not touch NSWindow.
public nonisolated enum WindowActionRequest: Sendable, Equatable {
  case new(from: PaneID)
  case close(from: PaneID)
  case closeAll
  case goto(target: GotoWindowTarget)
  case toggleFullscreen(from: PaneID)
  case toggleMaximize(from: PaneID)
  case toggleTabOverview(from: PaneID)
  case toggleAppVisibility
  case quit
  case checkForUpdates
  case openConfig
}

public nonisolated enum GotoWindowTarget: Sendable, Equatable {
  case previous
  case next
  case last
  case index(Int)
}
