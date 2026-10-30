import Foundation

/// Where the Agent Sessions popover resumes a recorded session. Unlike
/// `HandoffPlacement`, it includes `.inPlace`: a resume has no outgoing agent
/// to protect, so typing into an idle focused pane is a valid choice. Uses
/// the same persisted token shape as the hand-off placement.
public nonisolated enum AgentResumePlacement: Hashable, Sendable {
  case newTab
  case inPlace
  case split(ScriptSplitDirection)

  /// What a resume does when nothing chose otherwise.
  public static let `default`: AgentResumePlacement = .newTab

  public var target: ScriptTarget {
    switch self {
    case .newTab: return .newTab
    case .inPlace: return .focused
    case .split: return .split
    }
  }

  /// `nil` unless the placement is a split.
  public var direction: ScriptSplitDirection? {
    switch self {
    case .newTab, .inPlace: return nil
    case .split(let direction): return direction
    }
  }

  /// What the worktree offers the resume at the moment it is chosen.
  public struct Context: Hashable, Sendable {
    public var hasFocusedPane: Bool
    public var focusedPaneRunsAgent: Bool

    public init(hasFocusedPane: Bool, focusedPaneRunsAgent: Bool) {
      self.hasFocusedPane = hasFocusedPane
      self.focusedPaneRunsAgent = focusedPaneRunsAgent
    }

    /// The worktree's focused pane — the selected (or first) tab's
    /// last-focused pane, else its first pane — the same pane the script
    /// pipeline types into or splits. `lastFocusedPane` answers per tab.
    public init(worktree: Worktree, lastFocusedPane: (TabID) -> PaneID?) {
      let tabID = worktree.selectedTabID ?? worktree.tabs.first?.id
      let tab = worktree.tabs.first { $0.id == tabID }
      let lastFocused = tab.flatMap { lastFocusedPane($0.id) }
      let pane = tab?.panes.first { $0.id == lastFocused } ?? tab?.panes.first
      self.init(hasFocusedPane: pane != nil, focusedPaneRunsAgent: pane?.agentKind != nil)
    }

    /// The empty-terminal entry: no tab, so no pane to type into or split.
    public static let noFocusedPane = Context(hasFocusedPane: false, focusedPaneRunsAgent: false)

    /// Typing a resume command over a live agent session would corrupt it.
    public var allowsInPlace: Bool { hasFocusedPane && !focusedPaneRunsAgent }
  }

  /// The placement the picker shows on open. A remembered In Place that is
  /// not available shows as New Tab; the remembered value itself is kept.
  public func shown(in context: Context) -> AgentResumePlacement {
    self == .inPlace && !context.allowsInPlace ? .newTab : self
  }

  /// The placement the resume actually runs with: New Tab when In Place is
  /// not allowed or there is no pane to split.
  public func resolved(in context: Context) -> AgentResumePlacement {
    switch self {
    case .newTab: return .newTab
    case .inPlace: return context.allowsInPlace ? .inPlace : .newTab
    case .split: return context.hasFocusedPane ? self : .newTab
    }
  }

  // MARK: - Persistence

  /// One stable token per case — `tab`, `focused`, `split:right` — so the
  /// last choice can be remembered in a plain string default.
  public var persisted: String {
    switch self {
    case .newTab: return "tab"
    case .inPlace: return "focused"
    case .split(let direction): return "split:\(direction.rawValue)"
    }
  }

  public init?(persisted: String) {
    switch persisted {
    case "tab":
      self = .newTab
    case "focused":
      self = .inPlace
    default:
      let parts = persisted.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2, parts[0] == "split",
        let direction = ScriptSplitDirection(rawValue: parts[1])
      else { return nil }
      self = .split(direction)
    }
  }
}
