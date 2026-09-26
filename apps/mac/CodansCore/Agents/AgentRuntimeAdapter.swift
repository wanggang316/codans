import Foundation

/// Compatibility view for existing consumers of Agent identity and resume.
/// AgentRegistry composes the metadata, terminal parser, launch descriptor and
/// optional session resumer; Agent implementations live behind those boundaries.
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

/// Compatibility view of the single Agent registry.
public nonisolated enum AgentRuntimeAdapters {
  public static func adapter(for kind: AgentKind) -> any AgentRuntimeAdapter {
    RegisteredRuntimeAdapter(definition: AgentRegistry.definition(for: kind))
  }

  public static var all: [any AgentRuntimeAdapter] {
    AgentKind.allCases.map(adapter(for:))
  }
}

private nonisolated struct RegisteredRuntimeAdapter: AgentRuntimeAdapter {
  let definition: AgentDefinition
  var kind: AgentKind { definition.identity.kind }
  var displayName: String { definition.identity.displayName }
  var processNames: [String] { definition.identity.processNames }

  func resumeCommand(sessionID: String) -> String? {
    definition.sessionResumer?.resumeCommand(sessionID: sessionID)
  }

  func shortSessionID(_ sessionID: String) -> String {
    switch definition.identity.sessionIDDisplay {
    case .prefix: return String(sessionID.prefix(8))
    case .suffix: return String(sessionID.suffix(8))
    }
  }
}
