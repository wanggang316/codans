import Foundation

/// Where a hand-off starts the receiving agent. The two cases are the two
/// `ScriptTarget`s a hand-off may use; `.focused` is deliberately absent,
/// because the receiver must never type over the outgoing agent's pane.
/// A split is anchored on the source pane, so the receiver appears beside
/// the agent it takes over from.
public nonisolated enum HandoffPlacement: Hashable, Sendable {
  case newTab
  case split(ScriptSplitDirection)

  /// What a hand-off does when nothing chose otherwise.
  public static let `default`: HandoffPlacement = .newTab

  public var target: ScriptTarget {
    switch self {
    case .newTab: return .newTab
    case .split: return .split
    }
  }

  /// `nil` for a tab, where no direction applies.
  public var direction: ScriptSplitDirection? {
    switch self {
    case .newTab: return nil
    case .split(let direction): return direction
    }
  }

  /// From the wire fields of a hand-off request. A missing target is the
  /// default; `.focused` has no hand-off meaning and yields `nil`.
  public init?(target: ScriptTarget?, direction: ScriptSplitDirection?) {
    switch target {
    case nil, .newTab: self = .newTab
    case .split: self = .split(direction ?? .right)
    case .focused: return nil
    }
  }

  /// The flags `codans handoff to` takes for this placement, empty for the
  /// default so the kickoff line an agent runs stays as short as it was.
  public var cliArguments: [String] {
    switch self {
    case .newTab: return []
    case .split(let direction): return ["--split", direction.rawValue]
    }
  }

  // MARK: - Persistence

  /// One stable token per case — `tab`, `split:right` — so the last choice
  /// can be remembered in a plain string default.
  public var persisted: String {
    switch self {
    case .newTab: return "tab"
    case .split(let direction): return "split:\(direction.rawValue)"
    }
  }

  public init?(persisted: String) {
    if persisted == "tab" {
      self = .newTab
      return
    }
    let parts = persisted.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, parts[0] == "split",
      let direction = ScriptSplitDirection(rawValue: parts[1])
    else { return nil }
    self = .split(direction)
  }
}
