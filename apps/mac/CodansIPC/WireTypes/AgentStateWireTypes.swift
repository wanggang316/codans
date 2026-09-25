import CodansCore
import Foundation

extension IPC {
  /// One row of `agent.listStates`: an agent-bearing pane and its derived
  /// runtime state, as the sidebar's Agents View shows it. Ids are plain
  /// strings so the CLI prints the row as-is.
  public struct AgentStateEntry: Codable, Equatable, Sendable {
    public let paneID: String
    public let handle: String?
    /// `AgentKind.rawValue` and its display name.
    public let agent: String
    public let agentName: String
    /// `idle` / `working` / `blocked` / `error` / `finished`.
    public let state: String
    /// ISO 8601 instant of the last state transition.
    public let since: String
    public let sessionID: String?
    /// The pane's latest terminal title, when one was observed.
    public let title: String?
    public let projectID: String
    public let projectName: String
    public let worktreeID: String
    public let worktreeName: String
    public let tabID: String
    public let tabTitle: String?
    public let isFocused: Bool

    public init(
      paneID: String,
      handle: String?,
      agent: String,
      agentName: String,
      state: String,
      since: String,
      sessionID: String?,
      title: String?,
      projectID: String,
      projectName: String,
      worktreeID: String,
      worktreeName: String,
      tabID: String,
      tabTitle: String?,
      isFocused: Bool
    ) {
      self.paneID = paneID
      self.handle = handle
      self.agent = agent
      self.agentName = agentName
      self.state = state
      self.since = since
      self.sessionID = sessionID
      self.title = title
      self.projectID = projectID
      self.projectName = projectName
      self.worktreeID = worktreeID
      self.worktreeName = worktreeName
      self.tabID = tabID
      self.tabTitle = tabTitle
      self.isFocused = isFocused
    }
  }

  public struct AgentStateListResponse: Codable, Equatable, Sendable {
    public let count: Int
    public let agents: [AgentStateEntry]

    public init(agents: [AgentStateEntry]) {
      self.count = agents.count
      self.agents = agents
    }
  }

  /// What `agent.wait` waits for. The five states match `AgentStateEntry
  /// .state`; `changed` resolves on any transition away from the state seen
  /// when the wait was armed (including an agent appearing or leaving);
  /// `exit` resolves once no agent is bound to the pane any more.
  public enum AgentWaitCondition: String, Codable, CaseIterable, Sendable {
    case idle
    case working
    case blocked
    case error
    case finished
    case changed
    case exit
  }

  public struct AgentWaitRequest: Codable, Equatable, Sendable {
    public let paneID: PaneID
    public let until: AgentWaitCondition
    /// 1 through 600 000; the server clamps.
    public let timeoutMillis: Int

    public init(paneID: PaneID, until: AgentWaitCondition, timeoutMillis: Int) {
      self.paneID = paneID
      self.until = until
      self.timeoutMillis = timeoutMillis
    }
  }

  /// `satisfied == false` means the deadline passed; `state` is then the
  /// last observed state so the caller can decide what to do.
  public struct AgentWaitResponse: Codable, Equatable, Sendable {
    public let paneID: String
    public let until: String
    public let satisfied: Bool
    public let state: String?
    public let previousState: String?
    public let agent: String?
    public let waitedMs: Int

    public init(
      paneID: String,
      until: String,
      satisfied: Bool,
      state: String?,
      previousState: String?,
      agent: String?,
      waitedMs: Int
    ) {
      self.paneID = paneID
      self.until = until
      self.satisfied = satisfied
      self.state = state
      self.previousState = previousState
      self.agent = agent
      self.waitedMs = waitedMs
    }
  }
}
