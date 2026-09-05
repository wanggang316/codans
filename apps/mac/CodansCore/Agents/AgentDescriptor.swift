import Foundation

/// One selectable value in an agent's Model / Reasoning Effort / Execution
/// Mode picker. `id` is the stable token persisted on `AgentProfile`;
/// `label` is what the picker renders.
///
/// `arguments` carries the literal argv fragments a choice contributes.
/// Execution modes use it (each mode is its own flag set); Model and
/// Reasoning Effort leave it empty and are rendered through the
/// descriptor's `modelFlag` / `reasoningEffortFlag` instead, because those
/// two pass the choice's `id` through as the flag's value.
public nonisolated struct AgentLaunchChoice: Equatable, Sendable, Identifiable, Hashable {
  public let id: String
  public let label: String
  public let arguments: [String]

  public init(id: String, label: String, arguments: [String] = []) {
    self.id = id
    self.label = label
    self.arguments = arguments
  }
}

/// How an agent CLI spells a value-carrying option. Kept as data rather than
/// a closure so `AgentDescriptor` stays `Equatable` and testable.
public nonisolated enum AgentFlagStyle: Equatable, Sendable, Hashable {
  /// `--model gpt-5.1` — flag and value as two argv entries.
  case separate(String)
  /// `--model=gpt-5.1` — one argv entry.
  case joined(String)
  /// `-c model_reasoning_effort=high` — a config override pair, the form
  /// Codex uses for knobs that have no dedicated flag.
  case configOverride(key: String, flag: String)

  /// Renders this option for `value`, already shell-quoted where the value
  /// is interpolated.
  public func arguments(for value: String) -> [String] {
    switch self {
    case .separate(let flag):
      return [flag, ShellQuoting.quoted(value)]
    case .joined(let flag):
      return ["\(flag)=\(ShellQuoting.quoted(value))"]
    case .configOverride(let key, let flag):
      return [flag, ShellQuoting.quoted("\(key)=\(value)")]
    }
  }
}

/// How an agent CLI accepts an initial prompt while still starting its
/// interactive session. `nil` on a descriptor means codans has no verified
/// spelling for it — such an agent can be launched bare but cannot receive a
/// handoff kickoff, so it is not offered as a handoff destination.
public nonisolated enum AgentPromptStyle: Equatable, Sendable, Hashable {
  /// `claude 'prompt'` — the prompt is the trailing positional argument.
  case positional
  /// `gemini -i 'prompt'` — the prompt rides a flag.
  case flag(String)

  /// Renders the prompt as argv fragments, shell-quoted.
  public func arguments(for prompt: String) -> [String] {
    switch self {
    case .positional:
      return [ShellQuoting.quoted(prompt)]
    case .flag(let flag):
      return [flag, ShellQuoting.quoted(prompt)]
    }
  }
}

/// Static, per-agent launch metadata: the executable codans looks for on
/// `PATH`, the brand asset that identifies it, and the option catalogue its
/// CLI exposes. Everything the Agents settings pane renders and everything
/// `AgentLaunchCommand` needs to build an invocation comes from here, so
/// teaching codans about a new agent flag is a one-entry data edit.
///
/// Display identity is *not* duplicated here — it is read from the agent's
/// `AgentRuntimeAdapter`, which stays the single source of truth for what an
/// agent is called.
///
/// An empty option list means "this CLI has no such knob": the settings pane
/// omits the row entirely rather than showing a picker with one dead entry.
/// Only options we can spell correctly are listed; the rest is deliberately
/// left to `Extra Arguments`.
public nonisolated struct AgentDescriptor: Equatable, Sendable {
  public let kind: AgentKind
  /// Executable name resolved against the user's login `PATH`. Also the
  /// leading token of every rendered launch command.
  public let executable: String
  /// Asset-catalog name of the agent's brand glyph.
  public let iconAssetName: String
  /// One-line description of the glyph, shown under the Icon row.
  public let iconSummary: String

  public let modelFlag: AgentFlagStyle?
  public let models: [AgentLaunchChoice]
  public let reasoningEffortFlag: AgentFlagStyle?
  public let reasoningEfforts: [AgentLaunchChoice]
  /// Execution modes, most permissive last. The first entry is the
  /// "Standard" no-flag mode and is what a profile with no stored mode
  /// resolves to.
  public let executionModes: [AgentLaunchChoice]
  /// How this CLI takes a kickoff prompt, or `nil` when it cannot start
  /// interactively with one.
  public let promptStyle: AgentPromptStyle?

  public var displayName: String {
    AgentRuntimeAdapters.adapter(for: kind).displayName
  }

  public init(
    kind: AgentKind,
    executable: String,
    iconAssetName: String,
    iconSummary: String,
    modelFlag: AgentFlagStyle? = nil,
    models: [AgentLaunchChoice] = [],
    reasoningEffortFlag: AgentFlagStyle? = nil,
    reasoningEfforts: [AgentLaunchChoice] = [],
    executionModes: [AgentLaunchChoice] = [],
    promptStyle: AgentPromptStyle? = nil
  ) {
    self.kind = kind
    self.executable = executable
    self.iconAssetName = iconAssetName
    self.iconSummary = iconSummary
    self.modelFlag = modelFlag
    self.models = models
    self.reasoningEffortFlag = reasoningEffortFlag
    self.reasoningEfforts = reasoningEfforts
    self.executionModes = executionModes
    self.promptStyle = promptStyle
  }

  /// Whether a handoff can launch this agent with its kickoff prompt.
  public var supportsInitialPrompt: Bool { promptStyle != nil }

  /// Execution mode a profile resolves to when it stores none, or stores one
  /// that this agent no longer offers (agent swapped on an existing profile,
  /// hand-edited settings.json).
  public var defaultExecutionMode: AgentLaunchChoice? { executionModes.first }

  public func model(id: String?) -> AgentLaunchChoice? {
    guard let id else { return nil }
    return models.first { $0.id == id }
  }

  public func reasoningEffort(id: String?) -> AgentLaunchChoice? {
    guard let id else { return nil }
    return reasoningEfforts.first { $0.id == id }
  }

  public func executionMode(id: String?) -> AgentLaunchChoice? {
    guard let id, let match = executionModes.first(where: { $0.id == id }) else {
      return defaultExecutionMode
    }
    return match
  }
}

/// Total registry of launch descriptors. Exhaustive over `AgentKind`, so a
/// new agent case is a compile error until it declares how it launches.
public nonisolated enum AgentCatalog {
  /// Exhaustive over `AgentKind` so a new agent case is a compile error until
  /// it declares how it launches. The bodies live in the constants below —
  /// the switch stays a dispatcher.
  public static func descriptor(for kind: AgentKind) -> AgentDescriptor {
    switch kind {
    case .claudeCode: return claudeCode
    case .codex: return codex
    case .gemini: return gemini
    case .cursorAgent: return cursorAgent
    case .opencode: return opencode
    case .copilot: return copilot
    case .droid: return droid
    case .amp: return amp
    case .grok: return grok
    case .pi: return pi
    case .omp: return omp
    case .cline: return cline
    case .kimi: return kimi
    }
  }

  /// Every descriptor in `AgentKind.allCases` order.
  public static var all: [AgentDescriptor] {
    AgentKind.allCases.map(descriptor(for:))
  }

  /// Agents whose CLI takes the kickoff prompt as an argument, in catalogue
  /// order. A handoff can start any agent; for the rest it types the prompt
  /// into the pane once the agent is up.
  public static var handoffReceivers: [AgentKind] {
    all.filter(\.supportsInitialPrompt).map(\.kind)
  }

  // MARK: - Per-agent catalogues

  private static let claudeCode = AgentDescriptor(
    kind: .claudeCode,
    executable: "claude",
    iconAssetName: "claude-code",
    iconSummary: "Claude Code brand icon",
    modelFlag: .separate("--model"),
    models: [
      AgentLaunchChoice(id: "opus", label: "Opus"),
      AgentLaunchChoice(id: "sonnet", label: "Sonnet"),
      AgentLaunchChoice(id: "haiku", label: "Haiku"),
    ],
    executionModes: [
      AgentLaunchChoice(id: "standard", label: "Standard"),
      AgentLaunchChoice(
        id: "accept-edits", label: "Accept Edits",
        arguments: ["--permission-mode", "acceptEdits"]),
      AgentLaunchChoice(
        id: "plan", label: "Plan",
        arguments: ["--permission-mode", "plan"]),
      AgentLaunchChoice(
        id: "bypass", label: "Bypass Permissions",
        arguments: ["--permission-mode", "bypassPermissions"]),
    ],
    promptStyle: .positional
  )

  private static let codex = AgentDescriptor(
    kind: .codex,
    executable: "codex",
    iconAssetName: "codex",
    iconSummary: "Codex brand icon",
    modelFlag: .separate("--model"),
    models: [
      AgentLaunchChoice(id: "gpt-5.1-codex", label: "gpt-5.1-codex"),
      AgentLaunchChoice(id: "gpt-5.1", label: "gpt-5.1"),
      AgentLaunchChoice(id: "gpt-5-codex", label: "gpt-5-codex"),
    ],
    reasoningEffortFlag: .configOverride(key: "model_reasoning_effort", flag: "-c"),
    reasoningEfforts: [
      AgentLaunchChoice(id: "minimal", label: "Minimal"),
      AgentLaunchChoice(id: "low", label: "Low"),
      AgentLaunchChoice(id: "medium", label: "Medium"),
      AgentLaunchChoice(id: "high", label: "High"),
    ],
    executionModes: [
      AgentLaunchChoice(id: "standard", label: "Standard"),
      AgentLaunchChoice(id: "full-auto", label: "Full Auto", arguments: ["--full-auto"]),
      AgentLaunchChoice(
        id: "bypass", label: "Bypass Approvals",
        arguments: ["--dangerously-bypass-approvals-and-sandbox"]),
    ],
    promptStyle: .positional
  )

  private static let gemini = AgentDescriptor(
    kind: .gemini,
    executable: "gemini",
    iconAssetName: "gemini",
    iconSummary: "Gemini brand icon",
    modelFlag: .separate("--model"),
    models: [
      AgentLaunchChoice(id: "gemini-2.5-pro", label: "gemini-2.5-pro"),
      AgentLaunchChoice(id: "gemini-2.5-flash", label: "gemini-2.5-flash"),
    ],
    executionModes: [
      AgentLaunchChoice(id: "standard", label: "Standard"),
      AgentLaunchChoice(id: "yolo", label: "Auto-approve", arguments: ["--yolo"]),
    ],
    // `-i` / `--prompt-interactive`: seed the prompt and stay in the TUI.
    promptStyle: .flag("-i")
  )

  private static let cursorAgent = AgentDescriptor(
    kind: .cursorAgent,
    executable: "cursor-agent",
    iconAssetName: "cursor-agent",
    iconSummary: "Cursor Agent brand icon",
    // `cursor-agent [options] [prompt...]` — the trailing words start an
    // interactive session with that prompt.
    promptStyle: .positional
  )

  private static let opencode = AgentDescriptor(
    kind: .opencode,
    executable: "opencode",
    iconAssetName: "opencode",
    iconSummary: "OpenCode brand icon"
  )

  private static let copilot = AgentDescriptor(
    kind: .copilot,
    executable: "copilot",
    iconAssetName: "github-copilot",
    iconSummary: "GitHub Copilot brand icon"
  )

  private static let droid = AgentDescriptor(
    kind: .droid,
    executable: "droid",
    iconAssetName: "droid",
    iconSummary: "Droid brand icon"
  )

  private static let amp = AgentDescriptor(
    kind: .amp,
    executable: "amp",
    iconAssetName: "amp",
    iconSummary: "Amp brand icon"
  )

  private static let grok = AgentDescriptor(
    kind: .grok,
    executable: "grok",
    iconAssetName: "grok",
    iconSummary: "Grok Build brand icon",
    // `grok [OPTIONS] [PROMPT]` — "Initial prompt for the interactive
    // session, e.g. `grok \"fix the bug\"`".
    promptStyle: .positional
  )

  private static let pi = AgentDescriptor(
    kind: .pi,
    executable: "pi",
    iconAssetName: "pi",
    iconSummary: "Pi brand icon",
    // `pi [options] [--] [@files...] [messages...]` — trailing messages are
    // sent as the first turn, the same shape as its fork `omp`.
    promptStyle: .positional
  )

  private static let omp = AgentDescriptor(
    kind: .omp,
    executable: "omp",
    iconAssetName: "omp",
    iconSummary: "omp brand icon",
    // `omp [MESSAGES]` — a trailing message opens interactive mode with it
    // as the first turn.
    promptStyle: .positional
  )

  private static let cline = AgentDescriptor(
    kind: .cline,
    executable: "cline",
    iconAssetName: "cline",
    iconSummary: "Cline brand icon"
  )

  private static let kimi = AgentDescriptor(
    kind: .kimi,
    executable: "kimi",
    iconAssetName: "kimi",
    iconSummary: "Kimi brand icon"
  )
}
