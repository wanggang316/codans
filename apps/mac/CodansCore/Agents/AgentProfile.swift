import Foundation

/// A named launch preset for one coding agent. Profiles are what the user
/// actually picks — from the worktree toolbar's Agents menu and from the
/// Settings → Agents pane — while `AgentDescriptor` supplies the static
/// per-agent facts a profile is configured against.
///
/// Override fields are `nil`/empty when the user has not opted in, which
/// renders as "Runtime default": codans contributes no flag and the agent CLI
/// decides. Ids stored in `modelID` / `reasoningEffortID` / `executionModeID`
/// are resolved against the descriptor at render time, so a value that the
/// agent no longer offers (agent swapped on the profile, hand-edited
/// settings.json) degrades to the default instead of emitting a dead flag.
public nonisolated struct AgentProfile: Equatable, Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  /// Which agent this profile launches. Editable — the detail pane's Agent
  /// picker rewrites it, which is why every override below is validated
  /// against the descriptor rather than trusted.
  public var kind: AgentKind
  /// User-facing label. Empty falls back to the agent's display name.
  public var name: String
  /// Unchecked profiles stay configured but are hidden from the toolbar
  /// Agents menu. Mirrors the list pane's leading checkbox.
  public var isEnabled: Bool
  /// SF Symbol that replaces the agent's brand mark wherever this profile
  /// is drawn — list row, toolbar button, menu, spawned tab. `nil` keeps
  /// the brand mark. Lets two profiles for the same agent be told apart at
  /// a glance (a "Plan" Claude Code next to a "Build" one).
  public var systemImage: String?

  public var modelID: String?
  public var reasoningEffortID: String?
  public var executionModeID: String?

  /// Where the agent materializes — same surface vocabulary as
  /// `ScriptDefinition`, so the launch path can reuse the script dispatcher.
  public var target: ScriptTarget
  /// Consumed only when `target == .split`.
  public var direction: ScriptSplitDirection

  /// Free-form argv tail appended verbatim after every generated flag.
  /// The escape hatch for anything the descriptor's option catalogue does
  /// not spell.
  public var extraArguments: String
  /// Variables exported for the agent process only — rendered as an `env`
  /// prefix so the pane's own shell keeps the user's normal environment.
  public var envVars: [String: String]
  /// Redirects `HOME` to a codans-managed per-profile directory so the agent
  /// gets its own credentials / config / history instead of sharing the
  /// user's.
  public var usesDedicatedHome: Bool

  public init(
    id: UUID = UUID(),
    kind: AgentKind,
    name: String = "",
    isEnabled: Bool = true,
    systemImage: String? = nil,
    modelID: String? = nil,
    reasoningEffortID: String? = nil,
    executionModeID: String? = nil,
    target: ScriptTarget = .newTab,
    direction: ScriptSplitDirection = .right,
    extraArguments: String = "",
    envVars: [String: String] = [:],
    usesDedicatedHome: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.isEnabled = isEnabled
    self.systemImage = systemImage
    self.modelID = modelID
    self.reasoningEffortID = reasoningEffortID
    self.executionModeID = executionModeID
    self.target = target
    self.direction = direction
    self.extraArguments = extraArguments
    self.envVars = envVars
    self.usesDedicatedHome = usesDedicatedHome
  }

  /// User-visible label; falls back to the agent's own name when unnamed.
  public var displayName: String {
    name.isEmpty ? AgentCatalog.descriptor(for: kind).displayName : name
  }

  public var descriptor: AgentDescriptor {
    AgentCatalog.descriptor(for: kind)
  }

  /// Glyph identity for every surface that draws this profile. Falls back
  /// to the agent's brand mark when the user has set no override.
  public var icon: AgentIconRef {
    if let systemImage, !systemImage.isEmpty { return .symbol(systemImage) }
    return .brand(kind)
  }

  /// Value written to `Tab.icon` for a tab this profile spawns. The two
  /// `AgentIconRef` cases map onto the two `Tab.icon` forms exactly.
  public var tabIcon: String {
    switch icon {
    case .brand(let kind): return TabIconRef.icon(for: kind)
    case .symbol(let name): return name
    }
  }

  // MARK: - Seeding

  /// Agents seeded as profiles on a fresh install, in the order the Agents
  /// pane lists them. `AgentKind` carries a few extra cases that codans can
  /// *recognise* in a pane but does not ship a preset for; the user can add
  /// those from "Add Profile".
  public static let seededKinds: [AgentKind] = [
    .claudeCode, .codex, .gemini, .cursorAgent, .opencode,
    .copilot, .droid, .amp, .grok, .pi, .omp,
  ]

  /// Deterministic id for the seeded profile of `kind`. Derived from the raw
  /// value rather than random so a re-seed — fresh install, or a user who
  /// deleted the `agents` object from settings.json — reproduces the same
  /// ids, keeping any id-keyed state (toolbar selection, chords) valid.
  public static func seedID(for kind: AgentKind) -> UUID {
    let hex = kind.rawValue.utf8.map { String(format: "%02x", $0) }.joined()
    let padded = String((hex + String(repeating: "0", count: 32)).prefix(32))
    let groups = [0, 8, 12, 16, 20, 32]
    let segments = (0..<5).map { index -> String in
      let start = padded.index(padded.startIndex, offsetBy: groups[index])
      let end = padded.index(padded.startIndex, offsetBy: groups[index + 1])
      return String(padded[start..<end])
    }
    // Every segment is hex of a fixed width, so the string is always a valid
    // UUID; the fallback exists only to keep the signature non-optional.
    return UUID(uuidString: segments.joined(separator: "-")) ?? UUID()
  }

  public static func seeded(_ kind: AgentKind) -> AgentProfile {
    AgentProfile(id: seedID(for: kind), kind: kind)
  }

  /// The default profile list — one enabled preset per seeded agent.
  public static var defaults: [AgentProfile] {
    seededKinds.map(seeded)
  }

  // MARK: - Codable

  private enum CodingKeys: String, CodingKey {
    case id, kind, name, isEnabled, systemImage
    case modelID, reasoningEffortID, executionModeID
    case target, direction
    case extraArguments, envVars, usesDedicatedHome
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(UUID.self, forKey: .id)
    self.kind = try c.decode(AgentKind.self, forKey: .kind)
    self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    self.systemImage = try c.decodeIfPresent(String.self, forKey: .systemImage)
    self.modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
    self.reasoningEffortID = try c.decodeIfPresent(String.self, forKey: .reasoningEffortID)
    self.executionModeID = try c.decodeIfPresent(String.self, forKey: .executionModeID)
    self.target = try c.decodeIfPresent(ScriptTarget.self, forKey: .target) ?? .newTab
    self.direction = try c.decodeIfPresent(ScriptSplitDirection.self, forKey: .direction) ?? .right
    self.extraArguments = try c.decodeIfPresent(String.self, forKey: .extraArguments) ?? ""
    self.envVars = try c.decodeIfPresent([String: String].self, forKey: .envVars) ?? [:]
    self.usesDedicatedHome = try c.decodeIfPresent(Bool.self, forKey: .usesDedicatedHome) ?? false
  }

  /// Omit-when-default encoding, matching `ScriptDefinition`: a profile the
  /// user has not customised writes only its id, kind, and enabled flag.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(kind, forKey: .kind)
    if !name.isEmpty { try c.encode(name, forKey: .name) }
    if !isEnabled { try c.encode(isEnabled, forKey: .isEnabled) }
    try c.encodeIfPresent(systemImage, forKey: .systemImage)
    try c.encodeIfPresent(modelID, forKey: .modelID)
    try c.encodeIfPresent(reasoningEffortID, forKey: .reasoningEffortID)
    try c.encodeIfPresent(executionModeID, forKey: .executionModeID)
    if target != .newTab { try c.encode(target, forKey: .target) }
    if target == .split, direction != .right { try c.encode(direction, forKey: .direction) }
    if !extraArguments.isEmpty { try c.encode(extraArguments, forKey: .extraArguments) }
    if !envVars.isEmpty { try c.encode(envVars, forKey: .envVars) }
    if usesDedicatedHome { try c.encode(usesDedicatedHome, forKey: .usesDedicatedHome) }
  }
}

/// `agents` sub-tree of `settings.json`. Additive: files written before this
/// feature simply have no `agents` key and decode to `.default`, which seeds
/// the built-in presets.
public nonisolated struct AgentSettings: Equatable, Codable, Sendable {
  public var profiles: [AgentProfile]

  public init(profiles: [AgentProfile] = AgentProfile.defaults) {
    self.profiles = profiles
  }

  public static let `default` = AgentSettings()

  /// Profiles offered by the toolbar Agents menu, in list order.
  public var enabledProfiles: [AgentProfile] {
    profiles.filter(\.isEnabled)
  }

  public func profile(id: UUID) -> AgentProfile? {
    profiles.first { $0.id == id }
  }

  private enum CodingKeys: String, CodingKey {
    case profiles
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // A present-but-empty list is a real state (the user removed every
    // profile) and must survive a round trip — only an absent key re-seeds.
    self.profiles =
      try container.decodeIfPresent([AgentProfile].self, forKey: .profiles)
      ?? AgentProfile.defaults
  }
}
