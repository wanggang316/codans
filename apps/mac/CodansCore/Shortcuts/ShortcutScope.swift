import Foundation

/// Editability classification for a registered shortcut.
///
/// - `configurable`: user may rebind, disable, and reset. Participates in conflict detection
///   against other `.configurable` rows.
/// - `systemFixed`: shown in the Settings pane for completeness but read-only. Represents
///   chords whose behavior is owned by AppKit / system menus (e.g. `⌘,` Settings, `⌘Q`
///   Quit) — codans does not bind these dynamically; the schema lists them so users see
///   the chord exists.
/// - `localOnly`: not surfaced in the Settings pane. Reserved for future use by intra-modal
///   keys (Esc / Return inside dialogs, intra-control text-cursor movement) so the registry
///   can model them without polluting the configurable surface.
public enum ShortcutScope: String, Sendable, Hashable, Codable {
  case configurable
  case systemFixed
  case localOnly
}
