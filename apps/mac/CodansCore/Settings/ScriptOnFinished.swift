import Foundation

/// Action applied to the script's spawned pane / tab once the pty's child
/// process exits.
///
/// Only meaningful for targets that spawn a surface — i.e. `.newTab` and
/// `.split`. The runtime treats `.focused` as `.none` regardless of the stored
/// value because `sendInput` has no observable "command finished" boundary.
///
/// Validity by target:
/// - `.newTab` → `.none` or `.closeTab`
/// - `.split`  → `.none` or `.closePane`
/// - `.focused` → forced to `.none`
///
/// Invalid combinations (e.g. `.split` + `.closeTab`) are tolerated on read
/// and treated as `.none` at dispatch — the UI never produces them.
public enum ScriptOnFinished: String, Codable, Sendable, CaseIterable {
  case none
  case closePane
  case closeTab
}
