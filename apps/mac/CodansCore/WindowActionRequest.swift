import Foundation

/// Window / app-level intent decoded from a libghostty action. The Runtime
/// emits `TerminalEvent.windowActionRequested(request)`;
/// `WindowActionRouterFeature` dispatches to `WindowService`, `UpdatesClient`,
/// `AppLifecycleClient`, or `EditorClient` as appropriate.
///
/// `from:` carries the source Content's ID for intents that need to resolve
/// back to an `NSWindow`. The receiving router performs the mapping —
/// Runtime does not touch NSWindow.
public nonisolated enum WindowActionRequest: Sendable, Equatable {
  case new(from: ContentID)
  case close(from: ContentID)
  case closeAll
  case goto(target: GotoWindowTarget)
  case toggleFullscreen(from: ContentID)
  case toggleMaximize(from: ContentID)
  case toggleTabOverview(from: ContentID)
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
