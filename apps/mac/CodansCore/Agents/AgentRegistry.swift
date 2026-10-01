import Foundation

public nonisolated struct AgentIdentity: Sendable {
  public enum SessionIDDisplay: Sendable { case prefix, suffix }
  public let kind: AgentKind
  public let displayName: String
  public let processNames: [String]
  public let sessionIDDisplay: SessionIDDisplay
}

public nonisolated struct AgentDefinition: Sendable {
  public let identity: AgentIdentity
  public let launch: AgentDescriptor
  public let terminalParser: any AgentTerminalParser
  public let sessionResumer: (any AgentSessionResumer)?
}

/// The only exhaustive registration of Agent-specific capabilities.
public nonisolated enum AgentRegistry {
  public static func definition(for kind: AgentKind) -> AgentDefinition {
    switch kind {
    case .claudeCode: return claudeCode
    case .codex: return codex
    case .pi: return pi
    case .opencode: return opencode
    case .gemini: return gemini
    case .cursorAgent: return cursorAgent
    case .cline: return cline
    case .copilot: return copilot
    case .kimi: return kimi
    case .droid: return droid
    case .amp: return amp
    case .grok: return grok
    case .omp: return omp
    }
  }

  private static let claudeCode = AgentDefinition(
    identity: AgentIdentity(
      kind: .claudeCode, displayName: "Claude Code",
      processNames: ["claude", "claude-code"], sessionIDDisplay: .prefix),
    launch: AgentLaunchDescriptors.claudeCode,
    terminalParser: ClaudeCodeObservationParser(),
    sessionResumer: ClaudeCodeSessionResumer()
  )

  private static let codex = AgentDefinition(
    identity: AgentIdentity(
      kind: .codex, displayName: "Codex",
      processNames: ["codex"], sessionIDDisplay: .suffix),
    launch: AgentLaunchDescriptors.codex,
    terminalParser: CodexObservationParser(),
    sessionResumer: CodexSessionResumer()
  )

  private static let pi = AgentDefinition(
    identity: AgentIdentity(
      kind: .pi, displayName: "Pi",
      processNames: ["pi"], sessionIDDisplay: .prefix),
    launch: AgentLaunchDescriptors.pi,
    terminalParser: PiObservationParser(),
    sessionResumer: nil
  )

  private static let opencode = AgentDefinition(
    identity: AgentIdentity(
      kind: .opencode, displayName: "OpenCode",
      processNames: ["opencode", "open-code"], sessionIDDisplay: .prefix),
    launch: AgentLaunchDescriptors.opencode,
    terminalParser: OpenCodeObservationParser(),
    sessionResumer: nil
  )

  private static let gemini = AgentDefinition(
    identity: AgentIdentity(
      kind: .gemini, displayName: "Gemini CLI",
      processNames: ["gemini"], sessionIDDisplay: .prefix),
    launch: AgentLaunchDescriptors.gemini,
    terminalParser: GeminiObservationParser(),
    sessionResumer: nil
  )

  private static let cursorAgent = AgentDefinition(
    identity: AgentIdentity(
      kind: .cursorAgent, displayName: "Cursor Agent",
      processNames: ["cursor-agent"], sessionIDDisplay: .prefix),
    launch: AgentLaunchDescriptors.cursorAgent,
    terminalParser: CursorObservationParser(),
    sessionResumer: nil
  )

  private static let cline = AgentDefinition(
    identity: AgentIdentity(
      kind: .cline, displayName: "Cline",
      processNames: ["cline"], sessionIDDisplay: .prefix),
    launch: AgentLaunchDescriptors.cline,
    terminalParser: ClineObservationParser(),
    sessionResumer: nil
  )

  private static let copilot = AgentDefinition(
    identity: AgentIdentity(
      kind: .copilot, displayName: "GitHub Copilot",
      processNames: ["copilot", "github-copilot", "ghcs"], sessionIDDisplay: .prefix),
    launch: AgentLaunchDescriptors.copilot,
    terminalParser: CopilotObservationParser(),
    sessionResumer: nil
  )

  private static let kimi = AgentDefinition(
    identity: AgentIdentity(
      kind: .kimi, displayName: "Kimi",
      processNames: ["kimi", "kimi-code"], sessionIDDisplay: .prefix),
    launch: AgentLaunchDescriptors.kimi,
    terminalParser: KimiObservationParser(),
    sessionResumer: nil
  )

  private static let droid = AgentDefinition(
    identity: AgentIdentity(
      kind: .droid, displayName: "Droid",
      processNames: ["droid"], sessionIDDisplay: .prefix),
    launch: AgentLaunchDescriptors.droid,
    terminalParser: DroidObservationParser(),
    sessionResumer: nil
  )

  private static let amp = AgentDefinition(
    identity: AgentIdentity(
      kind: .amp, displayName: "Amp",
      processNames: ["amp", "amp-local"], sessionIDDisplay: .prefix),
    launch: AgentLaunchDescriptors.amp,
    terminalParser: AmpObservationParser(),
    sessionResumer: nil
  )

  private static let grok = AgentDefinition(
    identity: AgentIdentity(
      kind: .grok, displayName: "Grok Build",
      processNames: ["grok", "grok-cli"], sessionIDDisplay: .prefix),
    launch: AgentLaunchDescriptors.grok,
    terminalParser: GrokObservationParser(),
    sessionResumer: nil
  )

  private static let omp = AgentDefinition(
    identity: AgentIdentity(
      kind: .omp, displayName: "omp",
      processNames: ["omp"], sessionIDDisplay: .prefix),
    launch: AgentLaunchDescriptors.omp,
    terminalParser: OmpObservationParser(),
    sessionResumer: OmpSessionResumer()
  )

}
