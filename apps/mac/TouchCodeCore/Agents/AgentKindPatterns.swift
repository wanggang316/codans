import Foundation

/// Process-level classifier that maps a pane's foreground job to a known
/// `AgentKind`. The classifier intentionally ignores terminal title,
/// initial command, and notification text; the foreground process group is
/// the source of truth for agent identity.
public nonisolated enum AgentKindPatterns {
  /// Process names and executable basenames matched against the pane's
  /// current foreground process group.
  public static let processName: [AgentKind: [String]] = [
    .claudeCode: ["claude", "claude-code"],
    .codex: ["codex"],
    .pi: ["pi"],
    .opencode: ["opencode", "open-code"],
    .gemini: ["gemini"],
    .cursorAgent: ["cursor", "cursor-agent"],
    .cline: ["cline"],
    .copilot: ["copilot", "github-copilot", "ghcs"],
    .kimi: ["kimi", "kimi-code"],
    .droid: ["droid"],
    .amp: ["amp", "amp-local"],
  ]

  /// Runtime wrappers that commonly host CLI entrypoints. When one of
  /// these is the visible process name, command-line tokens are inspected
  /// for an agent binary or shim name.
  public static let wrapperProcessNames: Set<String> = [
    "node", "bun", "python", "python3", "ruby", "deno",
    "sh", "bash", "zsh", "fish", "tmux", "npx", "bunx",
  ]

  /// Classify from the pane's foreground process group. The highest
  /// scoring process candidate wins. Executable identity outranks wrapper
  /// command-line tokens so a child process named like an agent beats a
  /// generic `node` / `python` launcher that merely mentions one.
  public static func classify(foregroundJob job: ForegroundJob) -> AgentKind? {
    bestForegroundJobMatch(job)?.kind
  }

  private static func bestForegroundJobMatch(
    _ job: ForegroundJob
  ) -> (kind: AgentKind, score: Int)? {
    var best: (kind: AgentKind, score: Int, order: Int)?

    for process in job.processes {
      for candidate in processCandidates(process) {
        guard let kind = matchProcessCandidate(candidate.value) else { continue }
        let order = AgentKind.allCases.firstIndex(of: kind) ?? Int.max
        if best == nil
          || candidate.score > best!.score
          || (candidate.score == best!.score && order < best!.order)
        {
          best = (kind, candidate.score, order)
        }
      }
    }

    return best.map { ($0.kind, $0.score) }
  }

  private static func processCandidates(
    _ process: ForegroundProcess
  ) -> [(value: String, score: Int)] {
    var candidates: [(String, Int)] = [
      (process.argv0, 80),
      (process.processName, 70),
    ]

    let normalizedName = process.processName.lowercased()
    if wrapperProcessNames.contains(normalizedName) {
      candidates.append(contentsOf: process.commandTokens.map { ($0, 40) })
    }

    if normalizedName == "agent",
      process.commandLine.lowercased().contains("cursor-agent")
        || process.commandLine.lowercased().contains("cursor.app")
    {
      candidates.append(("cursor-agent", 60))
    }

    return candidates
  }

  private static func matchProcessCandidate(_ candidate: String) -> AgentKind? {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    guard !trimmed.isEmpty else { return nil }
    let basename = normalizeExecutableName((trimmed as NSString).lastPathComponent)
    let normalized = normalizeExecutableName(trimmed)

    for kind in AgentKind.allCases {
      guard let patterns = processName[kind] else { continue }
      for pattern in patterns {
        let lowered = pattern.lowercased()
        if basename == lowered || normalized == lowered {
          return kind
        }
      }
    }
    return nil
  }

  private static func normalizeExecutableName(_ raw: String) -> String {
    var value = raw.lowercased()
    if value.hasPrefix("-") {
      value.removeFirst()
    }
    if value.hasSuffix(".js") {
      value.removeLast(3)
    }
    return value
  }
}
