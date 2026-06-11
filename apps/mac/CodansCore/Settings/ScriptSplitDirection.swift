import Foundation

/// Which side of the focused pane a `target == .split` script splits to.
///
/// One-to-one with `SplitTree.NewDirection`; lives here as a separate enum so
/// the settings JSON schema stays decoupled from the internal split-tree wire
/// type. The runtime maps between the two at dispatch time.
public enum ScriptSplitDirection: String, Codable, Sendable, CaseIterable {
  case up
  case down
  case left
  case right
}
