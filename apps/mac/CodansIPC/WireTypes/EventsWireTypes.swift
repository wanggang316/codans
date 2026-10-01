import Foundation

extension IPC {
  /// A stream a subscriber can ask `events.subscribe` for.
  public enum EventTopic: String, Codable, Hashable, Sendable, CaseIterable {
    case hierarchy
    case agents
  }

  /// `events.subscribe` params. `topics == nil` means every topic. An
  /// unknown topic fails decoding, which the server reports as
  /// `invalidParams`, and so does an empty list — a client can never
  /// silently subscribe to nothing.
  public struct EventsSubscribeRequest: Codable, Equatable, Sendable {
    public let topics: [EventTopic]?

    public init(topics: [EventTopic]? = nil) {
      self.topics = topics
    }

    /// The topics this request resolves to.
    public var resolvedTopics: Set<EventTopic> {
      topics.map(Set.init) ?? Set(EventTopic.allCases)
    }
  }

  // MARK: - Hierarchy summary

  /// The Project → Worktree → Tab → Pane tree as a remote client renders
  /// it: ids, names, selection and agent kind, nothing a client does not
  /// need. It is deliberately a separate projection from the catalog's
  /// domain types so catalog-only fields can evolve without breaking a
  /// phone running an older build. Ids are plain UUID strings, like every
  /// other wire description.
  public struct HierarchySummary: Codable, Equatable, Sendable {
    public let projects: [ProjectSummary]
    public let selectedProjectID: String?
    /// The pane the Mac user is focused on: the selected tab's focused
    /// pane in the selected worktree. A phone lands here when it has no
    /// pane of its own to return to. Absent from older servers.
    public let activePaneID: String?

    public init(projects: [ProjectSummary], selectedProjectID: String?, activePaneID: String? = nil) {
      self.projects = projects
      self.selectedProjectID = selectedProjectID
      self.activePaneID = activePaneID
    }
  }

  public struct ProjectSummary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isRemote: Bool
    public let selectedWorktreeID: String?
    public let worktrees: [WorktreeSummary]

    public init(
      id: String,
      name: String,
      isRemote: Bool,
      selectedWorktreeID: String?,
      worktrees: [WorktreeSummary]
    ) {
      self.id = id
      self.name = name
      self.isRemote = isRemote
      self.selectedWorktreeID = selectedWorktreeID
      self.worktrees = worktrees
    }
  }

  public struct WorktreeSummary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let branch: String?
    public let isPinned: Bool
    public let selectedTabID: String?
    public let tabs: [TabSummary]

    public init(
      id: String,
      name: String,
      branch: String?,
      isPinned: Bool,
      selectedTabID: String?,
      tabs: [TabSummary]
    ) {
      self.id = id
      self.name = name
      self.branch = branch
      self.isPinned = isPinned
      self.selectedTabID = selectedTabID
      self.tabs = tabs
    }
  }

  public struct TabSummary: Codable, Equatable, Sendable {
    public let id: String
    /// App-session short handle (`t<n>`), when one is assigned.
    public let handle: String?
    /// What the sidebar shows: the user's name, else the last live title.
    public let title: String?
    public let focusedPaneID: String?
    public let panes: [PaneSummary]
    /// The tab's split tree, so a client can order `panes` the way they
    /// sit on screen and mirror the layout. Absent from older servers, and
    /// nil when the tree uses a node shape this build does not know.
    public let layout: SplitLayoutNode?
    /// The pane zoomed to fill the tab on the Mac, if any.
    public let zoomedPaneID: String?

    public init(
      id: String,
      handle: String?,
      title: String?,
      focusedPaneID: String?,
      panes: [PaneSummary],
      layout: SplitLayoutNode? = nil,
      zoomedPaneID: String? = nil
    ) {
      self.id = id
      self.handle = handle
      self.title = title
      self.focusedPaneID = focusedPaneID
      self.panes = panes
      self.layout = layout
      self.zoomedPaneID = zoomedPaneID
    }

    private enum CodingKeys: String, CodingKey {
      case id, handle, title, focusedPaneID, panes, layout, zoomedPaneID
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try c.decode(String.self, forKey: .id)
      handle = try c.decodeIfPresent(String.self, forKey: .handle)
      title = try c.decodeIfPresent(String.self, forKey: .title)
      focusedPaneID = try c.decodeIfPresent(String.self, forKey: .focusedPaneID)
      panes = try c.decode([PaneSummary].self, forKey: .panes)
      // A layout from a newer server must not cost the client the whole
      // summary; the flat pane list still works without it.
      layout = (try? c.decodeIfPresent(SplitLayoutNode.self, forKey: .layout)) ?? nil
      zoomedPaneID = try c.decodeIfPresent(String.self, forKey: .zoomedPaneID)
    }
  }

  /// One node of a tab's split tree on the wire:
  /// `{"leaf": "<paneID>"}` or
  /// `{"split": {"direction": "horizontal", "ratio": 0.5, "left": …, "right": …}}`.
  /// A `horizontal` split puts `left` beside `right`; a `vertical` one puts
  /// `left` above `right`. `ratio` is the share `left` takes.
  public indirect enum SplitLayoutNode: Codable, Equatable, Sendable {
    case leaf(paneID: String)
    case split(direction: SplitLayoutDirection, ratio: Double, left: SplitLayoutNode, right: SplitLayoutNode)

    /// Pane ids in on-screen order: left to right, top to bottom.
    public var paneIDs: [String] {
      switch self {
      case .leaf(let paneID): return [paneID]
      case .split(_, _, let left, let right): return left.paneIDs + right.paneIDs
      }
    }

    private enum CodingKeys: String, CodingKey {
      case leaf, split
    }

    private struct SplitBody: Codable {
      let direction: SplitLayoutDirection
      let ratio: Double
      let left: SplitLayoutNode
      let right: SplitLayoutNode
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      if let paneID = try c.decodeIfPresent(String.self, forKey: .leaf) {
        self = .leaf(paneID: paneID)
      } else if let body = try c.decodeIfPresent(SplitBody.self, forKey: .split) {
        self = .split(direction: body.direction, ratio: body.ratio, left: body.left, right: body.right)
      } else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "layout node is neither leaf nor split"))
      }
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .leaf(let paneID):
        try c.encode(paneID, forKey: .leaf)
      case .split(let direction, let ratio, let left, let right):
        try c.encode(SplitBody(direction: direction, ratio: ratio, left: left, right: right), forKey: .split)
      }
    }
  }

  public enum SplitLayoutDirection: String, Codable, Equatable, Sendable {
    /// Children side by side.
    case horizontal
    /// Children stacked.
    case vertical
  }

  public struct PaneSummary: Codable, Equatable, Sendable {
    public let id: String
    /// App-session short handle (`p<n>`), when one is assigned.
    public let handle: String?
    /// The latest terminal title, when one was observed.
    public let title: String?
    /// `AgentKind.rawValue` of the agent bound to the pane, if any. A plain
    /// string so an agent kind newer than the client still decodes.
    public let agent: String?
    public let labels: [String]
    /// The shell's working directory as it last reported it, else the
    /// directory the pane was opened in.
    public let cwd: String?
    /// Whether the pane has a live terminal on the Mac. Input needs one;
    /// without it `terminal.sendEvents` answers `unsupported`. Absent from
    /// older servers.
    public let isLive: Bool?

    public init(
      id: String,
      handle: String?,
      title: String?,
      agent: String?,
      labels: [String],
      cwd: String? = nil,
      isLive: Bool? = nil
    ) {
      self.id = id
      self.handle = handle
      self.title = title
      self.agent = agent
      self.labels = labels
      self.cwd = cwd
      self.isLive = isLive
    }
  }

  // MARK: - Frames

  /// Full state sent as the first frame of every subscription. Sections
  /// for topics the subscriber did not ask for are nil.
  public struct EventsSnapshot: Codable, Equatable, Sendable {
    public let hierarchy: HierarchySummary?
    public let agents: [AgentStateEntry]?

    public init(hierarchy: HierarchySummary?, agents: [AgentStateEntry]?) {
      self.hierarchy = hierarchy
      self.agents = agents
    }
  }

  /// Agent-state delta: rows to insert or replace (keyed by `paneID`) and
  /// panes whose agent went away.
  public struct AgentStatesDelta: Codable, Equatable, Sendable {
    public let upserted: [AgentStateEntry]
    public let removedPaneIDs: [String]

    public init(upserted: [AgentStateEntry], removedPaneIDs: [String]) {
      self.upserted = upserted
      self.removedPaneIDs = removedPaneIDs
    }
  }

  /// What one `events.subscribe` stream frame carries.
  public enum EventPayload: Equatable, Sendable {
    /// Always the first frame; the client replaces its whole model.
    case snapshot(EventsSnapshot)
    /// Whole-section replacement of the hierarchy summary.
    case hierarchyChanged(HierarchySummary)
    case agentStatesChanged(AgentStatesDelta)
    /// Sent after a quiet period so a client can detect a half-open link.
    case heartbeat
    /// A kind this build does not know, from a newer server. Clients
    /// ignore it instead of failing the stream.
    case unknown(kind: String)

    public var kind: String {
      switch self {
      case .snapshot: return "snapshot"
      case .hierarchyChanged: return "hierarchyChanged"
      case .agentStatesChanged: return "agentStatesChanged"
      case .heartbeat: return "heartbeat"
      case .unknown(let kind): return kind
      }
    }
  }

  /// One `events.subscribe` stream frame (the `result` of a `stream: true`
  /// response). Flat on the wire, discriminated by `kind`:
  /// `{"seq": 3, "kind": "agentStatesChanged", "upserted": [...], "removedPaneIDs": [...]}`.
  /// `seq` increases by one per frame within a subscription.
  public struct EventFrame: Codable, Equatable, Sendable {
    public let seq: Int
    public let payload: EventPayload

    public init(seq: Int, payload: EventPayload) {
      self.seq = seq
      self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
      case seq, kind, hierarchy, agents, upserted, removedPaneIDs
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      seq = try c.decode(Int.self, forKey: .seq)
      let kind = try c.decode(String.self, forKey: .kind)
      switch kind {
      case "snapshot":
        payload = .snapshot(
          EventsSnapshot(
            hierarchy: try c.decodeIfPresent(HierarchySummary.self, forKey: .hierarchy),
            agents: try c.decodeIfPresent([AgentStateEntry].self, forKey: .agents)
          ))
      case "hierarchyChanged":
        payload = .hierarchyChanged(try c.decode(HierarchySummary.self, forKey: .hierarchy))
      case "agentStatesChanged":
        payload = .agentStatesChanged(
          AgentStatesDelta(
            upserted: try c.decode([AgentStateEntry].self, forKey: .upserted),
            removedPaneIDs: try c.decode([String].self, forKey: .removedPaneIDs)
          ))
      case "heartbeat":
        payload = .heartbeat
      default:
        payload = .unknown(kind: kind)
      }
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(seq, forKey: .seq)
      try c.encode(payload.kind, forKey: .kind)
      switch payload {
      case .snapshot(let snapshot):
        try c.encodeIfPresent(snapshot.hierarchy, forKey: .hierarchy)
        try c.encodeIfPresent(snapshot.agents, forKey: .agents)
      case .hierarchyChanged(let hierarchy):
        try c.encode(hierarchy, forKey: .hierarchy)
      case .agentStatesChanged(let delta):
        try c.encode(delta.upserted, forKey: .upserted)
        try c.encode(delta.removedPaneIDs, forKey: .removedPaneIDs)
      case .heartbeat, .unknown:
        break
      }
    }
  }
}
