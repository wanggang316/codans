import CodansCore
import Foundation

extension IPC {
  /// One row of `agent.listProfiles`: the profile as the toolbar Agents
  /// menu would present it, plus what the CLI needs to pick and launch it.
  public struct AgentProfileSummary: Codable, Equatable, Sendable {
    public let id: UUID
    /// User-facing label (`AgentProfile.displayName`).
    public let name: String
    /// `AgentKind.rawValue` of the agent the profile launches.
    public let agent: String
    public let agentName: String
    public let isEnabled: Bool
    /// `nil` when the app has not finished probing the shell for installed
    /// agents; callers must not read that as "missing".
    public let isInstalled: Bool?
    /// Whether the agent can start with a kickoff prompt (and so receive a
    /// handoff).
    public let supportsPrompt: Bool
    /// The exact command a launch types into the pane.
    public let command: String

    public init(
      id: UUID,
      name: String,
      agent: String,
      agentName: String,
      isEnabled: Bool,
      isInstalled: Bool?,
      supportsPrompt: Bool,
      command: String
    ) {
      self.id = id
      self.name = name
      self.agent = agent
      self.agentName = agentName
      self.isEnabled = isEnabled
      self.isInstalled = isInstalled
      self.supportsPrompt = supportsPrompt
      self.command = command
    }
  }

  public struct AgentProfileListResponse: Codable, Equatable, Sendable {
    public let profiles: [AgentProfileSummary]

    public init(profiles: [AgentProfileSummary]) {
      self.profiles = profiles
    }
  }

  /// Params for `agent.launch`. `profile` names a profile by id or display
  /// name; when absent, `agent` picks the first enabled profile for that
  /// agent (falling back to the agent's bare preset). Placement overrides
  /// are optional — the profile's saved placement applies when both are nil.
  public struct AgentLaunchRequest: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let worktreeID: WorktreeID
    public let profile: String?
    public let agent: String?
    public let prompt: String?
    public let target: ScriptTarget?
    public let direction: ScriptSplitDirection?
    /// `false` leaves the user's selection and focus where they are.
    public let focus: Bool

    public init(
      projectID: ProjectID,
      worktreeID: WorktreeID,
      profile: String? = nil,
      agent: String? = nil,
      prompt: String? = nil,
      target: ScriptTarget? = nil,
      direction: ScriptSplitDirection? = nil,
      focus: Bool = true
    ) {
      self.projectID = projectID
      self.worktreeID = worktreeID
      self.profile = profile
      self.agent = agent
      self.prompt = prompt
      self.target = target
      self.direction = direction
      self.focus = focus
    }
  }

  /// Result for `agent.launch`. `tabID` / `paneID` are nil when the launch
  /// typed into the focused pane instead of creating a surface.
  public struct AgentLaunchResponse: Codable, Equatable, Sendable {
    public let profileID: UUID
    public let profileName: String
    public let agent: String
    public let command: String
    public let tabID: TabID?
    public let paneID: PaneID?

    public init(
      profileID: UUID,
      profileName: String,
      agent: String,
      command: String,
      tabID: TabID?,
      paneID: PaneID?
    ) {
      self.profileID = profileID
      self.profileName = profileName
      self.agent = agent
      self.command = command
      self.tabID = tabID
      self.paneID = paneID
    }
  }
}
