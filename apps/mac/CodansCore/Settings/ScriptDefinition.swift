import Carbon.HIToolbox
import Foundation

/// User-defined script attached to a Project. Surfaced in the Scripts
/// sub-pane, the Command Palette, and the WorktreeHeader Run split-button.
///
/// `kind` supplies the *default* visual identity (name, icon, tint). A
/// per-command `systemImage` / `tintColor` override always wins over the
/// kind default at render time, so a command can keep its kind (and the
/// kind-derived name fallback) while showing a custom icon or colour.
///
/// `target` / `direction` / `onFinished` / `focus` describe **how** the
/// script materializes at run time:
/// - `target` picks between writing into the focused pane, a new tab, or a
///   split off the focused pane.
/// - `direction` is consumed only when `target == .split`.
/// - `onFinished` is consumed only for surface-spawning targets (`.newTab`,
///   `.split`); `.focused` has no observable completion boundary so the
///   runtime treats it as `.none` regardless.
/// - `focus` controls whether the spawned tab/pane steals first-responder
///   focus from the user. Consumed only for surface-spawning targets;
///   `.focused` writes into the already-focused pane and ignores `focus`.
public nonisolated struct ScriptDefinition: Equatable, Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  public var kind: ScriptKind
  public var name: String
  public var command: String
  public var systemImage: String?
  /// Filename of a user-uploaded custom icon stored under the app's managed
  /// `command-icons/` directory (see the app-layer `CommandIconStore`). When
  /// set, it takes precedence over `systemImage` / the kind default at render
  /// time. `nil` means "use an SF Symbol". Stored as a bare filename (not an
  /// absolute path) so `settings.json` stays portable and home-relative.
  public var customIconPath: String?
  public var tintColor: ScriptTintColor?
  public var target: ScriptTarget
  public var direction: ScriptSplitDirection
  public var onFinished: ScriptOnFinished
  /// When `true` (default), running a `.newTab` / `.split` script switches
  /// the user to the spawned tab/pane. When `false`, the surface is
  /// created in the background — the tab strip's executing badge is the
  /// only signal that something is running.
  public var focus: Bool
  /// Optional global keyboard chord (e.g. ⌘⇧R) attached to this
  /// script. nil = no shortcut. Reuses the same `ShortcutBinding`
  /// type the system Settings → Shortcuts page uses, so the chord
  /// recorder, display helpers (`ShortcutDisplay`), and SwiftUI
  /// adapter are all shared.
  public var keyboardShortcut: ShortcutBinding?

  public init(
    id: UUID = UUID(),
    kind: ScriptKind = .run,
    name: String = "",
    command: String = "",
    systemImage: String? = nil,
    customIconPath: String? = nil,
    tintColor: ScriptTintColor? = nil,
    target: ScriptTarget = .newTab,
    direction: ScriptSplitDirection = .right,
    onFinished: ScriptOnFinished = .none,
    focus: Bool = true,
    keyboardShortcut: ShortcutBinding? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.command = command
    self.systemImage = systemImage
    self.customIconPath = customIconPath
    self.tintColor = tintColor
    self.target = target
    self.direction = direction
    self.onFinished = onFinished
    self.focus = focus
    self.keyboardShortcut = keyboardShortcut
  }

  /// Stable id for the built-in Run default. Fixed (not random) so SwiftUI
  /// identity / selection stay put across renders while the default is still
  /// virtual, and so a materialized copy keeps one well-known id per Project.
  public static let builtinRunID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

  /// The built-in Run command every Project shows by default until it defines
  /// its own Run. Surfaced by the Commands table; it materializes into
  /// `ProjectSettings.scripts` the first time the user edits it. Ships with a
  /// ⌘R default chord — the conventional "Run" accelerator — which the
  /// materialized copy carries over unless the user clears or rebinds it.
  public static let builtinRun = ScriptDefinition(
    id: builtinRunID,
    kind: .run,
    keyboardShortcut: ShortcutBinding(keyCode: UInt16(kVK_ANSI_R), modifiers: .command)
  )

  /// User-visible label. Falls back to the kind's default when the user
  /// has not named the script.
  public var displayName: String {
    name.isEmpty ? kind.defaultName : name
  }

  /// SF Symbol used by view-side icons. A per-command override wins;
  /// otherwise the kind default applies.
  public var resolvedSystemImage: String {
    if let systemImage, !systemImage.isEmpty {
      return systemImage
    }
    return kind.defaultSystemImage
  }

  /// Tint colour used by view-side icons / button accents. A per-command
  /// override wins; otherwise the kind default applies.
  public var resolvedTintColor: ScriptTintColor {
    tintColor ?? kind.defaultTintColor
  }

  /// Validates `onFinished` against `target`. The UI never writes invalid
  /// combinations, but a hand-edited `settings.json` could; the runtime
  /// reads through this so dispatch is defensive.
  public var resolvedOnFinished: ScriptOnFinished {
    switch target {
    case .focused:
      return .none
    case .newTab:
      return onFinished == .closeTab ? .closeTab : .none
    case .split:
      return onFinished == .closePane ? .closePane : .none
    }
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, name, command, systemImage, customIconPath, tintColor
    case target, direction, onFinished, focus
    case keyboardShortcut
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(UUID.self, forKey: .id)
    self.kind = try c.decodeIfPresent(ScriptKind.self, forKey: .kind) ?? .run
    self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
    self.systemImage = try c.decodeIfPresent(String.self, forKey: .systemImage)
    self.customIconPath = try c.decodeIfPresent(String.self, forKey: .customIconPath)
    self.tintColor = try c.decodeIfPresent(ScriptTintColor.self, forKey: .tintColor)
    self.target = try c.decodeIfPresent(ScriptTarget.self, forKey: .target) ?? .newTab
    self.direction = try c.decodeIfPresent(ScriptSplitDirection.self, forKey: .direction) ?? .right
    self.onFinished = try c.decodeIfPresent(ScriptOnFinished.self, forKey: .onFinished) ?? .none
    self.focus = try c.decodeIfPresent(Bool.self, forKey: .focus) ?? true
    self.keyboardShortcut = try c.decodeIfPresent(ShortcutBinding.self, forKey: .keyboardShortcut)
  }

  /// Omit-when-default encoding. Empty strings, nil overrides, and any field
  /// at its default value do not appear on disk so the JSON stays minimal.
  /// `direction` is only emitted when `target == .split`. `onFinished` is
  /// only emitted when the validated value is non-`.none`. `focus` is only
  /// emitted when the user opted out of the default (true) for a surface-
  /// spawning target — `.focused` ignores `focus` so it is never emitted.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(kind, forKey: .kind)
    if !name.isEmpty {
      try c.encode(name, forKey: .name)
    }
    if !command.isEmpty {
      try c.encode(command, forKey: .command)
    }
    try c.encodeIfPresent(systemImage, forKey: .systemImage)
    try c.encodeIfPresent(customIconPath, forKey: .customIconPath)
    try c.encodeIfPresent(tintColor, forKey: .tintColor)
    if target != .newTab {
      try c.encode(target, forKey: .target)
    }
    if target == .split, direction != .right {
      try c.encode(direction, forKey: .direction)
    }
    let validatedOnFinished = resolvedOnFinished
    if validatedOnFinished != .none {
      try c.encode(validatedOnFinished, forKey: .onFinished)
    }
    if target != .focused, !focus {
      try c.encode(focus, forKey: .focus)
    }
    // Only persist the chord when the user explicitly bound one. The
    // recorder enforces presence-of-modifier + non-zero keyCode at
    // capture time so a saved chord is always bindable here.
    if let chord = keyboardShortcut, chord.isEnabled, chord.keyCode != 0 {
      try c.encode(chord, forKey: .keyboardShortcut)
    }
  }
}
