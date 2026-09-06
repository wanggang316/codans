import Foundation

/// Per-agent runtime adapter: the single place that knows how to observe
/// and reattach one coding-agent CLI. Display identity, the process names
/// the foreground-job classifier matches, and the resume invocation all
/// live behind this protocol, so supporting a new agent — or teaching an
/// existing one to resume — touches one adapter instead of scattered
/// switches.
///
/// Resume contract — resuming is side-effect free:
/// - `resumeCommand(sessionID:)` renders no execution-mode flags
///   (permission mode, sandbox, model, prompt overrides): the reattached
///   session runs exactly as the user last configured it;
/// - the command never mutates the source session's recorded state — it
///   only reattaches to it.
///
/// `AgentRuntimeAdapterTests` asserts this contract for every registered
/// adapter.
public nonisolated protocol AgentRuntimeAdapter: Sendable {
  /// The agent this adapter describes.
  var kind: AgentKind { get }

  /// User-facing label rendered in the status-bar popover and any other
  /// agent-aware UI.
  var displayName: String { get }

  /// Process names and executable basenames matched against a pane's
  /// foreground process group by `AgentKindPatterns.classify`.
  var processNames: [String] { get }

  /// Shell command that reattaches the agent CLI to `sessionID`, or nil
  /// when the CLI exposes no local session store with a resume entry
  /// point. See the protocol doc for the side-effect-free contract.
  func resumeCommand(sessionID: String) -> String?

  /// Compact display form of a session id for row layouts.
  func shortSessionID(_ sessionID: String) -> String
}

nonisolated extension AgentRuntimeAdapter {
  public func resumeCommand(sessionID: String) -> String? { nil }

  public func shortSessionID(_ sessionID: String) -> String {
    String(sessionID.prefix(8))
  }
}

/// Total registry of runtime adapters. The factory switches exhaustively
/// over `AgentKind`, so adding a case without registering an adapter is a
/// compile error.
public nonisolated enum AgentRuntimeAdapters {
  public static func adapter(for kind: AgentKind) -> any AgentRuntimeAdapter {
    switch kind {
    case .claudeCode:
      return ClaudeCodeAdapter()
    case .codex:
      return CodexAdapter()
    case .pi:
      return ObservedAgentAdapter(kind: .pi, displayName: "Pi", processNames: ["pi"])
    case .opencode:
      return ObservedAgentAdapter(
        kind: .opencode, displayName: "OpenCode", processNames: ["opencode", "open-code"])
    case .gemini:
      return ObservedAgentAdapter(
        kind: .gemini, displayName: "Gemini CLI", processNames: ["gemini"])
    case .cursorAgent:
      return ObservedAgentAdapter(
        kind: .cursorAgent, displayName: "Cursor Agent", processNames: ["cursor-agent"])
    case .cline:
      return ObservedAgentAdapter(kind: .cline, displayName: "Cline", processNames: ["cline"])
    case .copilot:
      return ObservedAgentAdapter(
        kind: .copilot, displayName: "GitHub Copilot",
        processNames: ["copilot", "github-copilot", "ghcs"])
    case .kimi:
      return ObservedAgentAdapter(
        kind: .kimi, displayName: "Kimi", processNames: ["kimi", "kimi-code"])
    case .droid:
      return ObservedAgentAdapter(kind: .droid, displayName: "Droid", processNames: ["droid"])
    case .amp:
      return ObservedAgentAdapter(
        kind: .amp, displayName: "Amp", processNames: ["amp", "amp-local"])
    case .grok:
      return ObservedAgentAdapter(
        kind: .grok, displayName: "Grok Build", processNames: ["grok", "grok-cli"])
    case .omp:
      return OmpAdapter()
    }
  }

  /// All adapters, in `AgentKind.allCases` order.
  public static var all: [any AgentRuntimeAdapter] {
    AgentKind.allCases.map(adapter(for:))
  }

  /// Single-quote wrap with the standard `'\''` escape. Session ids are
  /// UUID/ULID-shaped today, but they originate from files we don't own —
  /// quote instead of trusting the charset.
  static func shellQuoted(_ raw: String) -> String {
    ShellQuoting.quoted(raw)
  }
}

/// Claude Code: sessions live under `~/.claude/projects/<munged-cwd>/`
/// and reattach via `claude --resume <id>`.
nonisolated struct ClaudeCodeAdapter: AgentRuntimeAdapter {
  let kind: AgentKind = .claudeCode
  let displayName = "Claude Code"
  let processNames = ["claude", "claude-code"]

  func resumeCommand(sessionID: String) -> String? {
    "claude --resume \(AgentRuntimeAdapters.shellQuoted(sessionID))"
  }
}

/// Codex: rollouts live under `~/.codex/sessions/` and reattach via
/// `codex resume <id>`.
nonisolated struct CodexAdapter: AgentRuntimeAdapter {
  let kind: AgentKind = .codex
  let displayName = "Codex"
  let processNames = ["codex"]

  func resumeCommand(sessionID: String) -> String? {
    "codex resume \(AgentRuntimeAdapters.shellQuoted(sessionID))"
  }

  /// Codex ids are ULIDs whose leading bytes encode the timestamp and so
  /// repeat across sessions — take the tail instead of the prefix.
  func shortSessionID(_ sessionID: String) -> String {
    String(sessionID.suffix(8))
  }
}

/// Data-only adapter for agents codans can observe in a pane but not yet
/// reattach: no local session store with a resume entry point is wired up.
nonisolated struct ObservedAgentAdapter: AgentRuntimeAdapter {
  let kind: AgentKind
  let displayName: String
  let processNames: [String]
}

/// omp (oh-my-pi): sessions live under `~/.omp/agent/sessions/` and
/// reattach via `omp --resume <id>` (the CLI resolves a session by id
/// prefix regardless of the launching directory).
nonisolated struct OmpAdapter: AgentRuntimeAdapter {
  let kind: AgentKind = .omp
  let displayName = "omp"
  let processNames = ["omp"]

  func resumeCommand(sessionID: String) -> String? {
    "omp --resume \(AgentRuntimeAdapters.shellQuoted(sessionID))"
  }
}
