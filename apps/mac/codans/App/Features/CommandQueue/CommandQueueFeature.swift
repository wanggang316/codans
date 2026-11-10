import CodansCore
import ComposableArchitecture
import Foundation

/// Editor state for the Command Queue panel (⌘L).
///
/// Only the draft lives here. The pane overlay reads the queue from the live
/// catalog. This keeps editor state separate from commands managed by the runner.
@Reducer
struct CommandQueueFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    var id: PaneID { paneID }

    /// Pane the panel is editing. Fixed for the presentation's lifetime —
    /// re-opening on another pane replaces the whole state.
    let paneID: PaneID
    var draft: String = ""
    var mode: Mode = .afterCurrentTask
    /// First (or only) fire time for `.scheduled`. Seeded a few minutes out
    /// so the date picker opens on a plausible value rather than "now",
    /// which would fire before the user finishes typing.
    var scheduledAt: Date
    var repeatEnabled: Bool = false
    var repeatAmount: Int = 30
    var repeatUnit: IntervalUnit = .minutes
    /// How the draft calls the skills of the agent running in the pane.
    /// `none` until `onAppear` reads the pane, and while it offers no skills.
    var skillLocation: SkillLocation = .none
    /// Agent Skills the pane's agent can call, for draft completion.
    var skills: [AgentSkillEntry] = []
    /// What `skills` were read for. The pane's agent can change while the
    /// panel is open, so the skills of another scope are never shown.
    var skillsScope: SkillScope?
    /// Why the draft offers no skills, for the Skills button's tooltip.
    /// `nil` when typing the call prefix opens the list.
    var skillsUnavailableReason: String? = Self.noAgentReason

    static let noAgentReason = "Skill suggestions need an agent running in this pane"
    static let unreadableLaunchReason =
      "Skill suggestions are not available: codans cannot read how this agent was started"

    init(paneID: PaneID, now: Date = Date()) {
      self.paneID = paneID
      self.scheduledAt = Self.defaultScheduleDate(from: now)
    }

    /// `now + 10 min`, floored to the minute so the picker shows a round
    /// value instead of a stray seconds component.
    static func defaultScheduleDate(from now: Date) -> Date {
      let target = now.addingTimeInterval(600).timeIntervalSinceReferenceDate
      return Date(timeIntervalSinceReferenceDate: (target / 60).rounded(.down) * 60)
    }

    /// Which of the three send timings the draft will use. `.now` is not a
    /// queue timing — it writes to the pane immediately and never becomes an
    /// entry (see `QueuedCommandTiming`). Declared in menu order, with the
    /// default first.
    enum Mode: String, CaseIterable, Equatable {
      case afterCurrentTask
      case now
      case scheduled

      var title: String {
        switch self {
        case .now: return "Send now"
        case .afterCurrentTask: return "After task"
        case .scheduled: return "Schedule"
        }
      }
    }

    /// Repeat interval, or `nil` when repeating is off / the amount is not a
    /// positive number of units.
    var repeatInterval: TimeInterval? {
      guard repeatEnabled, repeatAmount > 0 else { return nil }
      return TimeInterval(repeatAmount) * repeatUnit.seconds
    }

    /// Trimmed at the ends only: a line break inside the draft is part of
    /// the prompt and is delivered as one.
    var trimmedDraft: String {
      draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSubmit: Bool { !trimmedDraft.isEmpty }
  }

  /// The agent process a skill scan reads for, and the directory it
  /// searches project skills from.
  struct SkillScope: Equatable, Sendable {
    var pid: Int32
    var launch: SkillLaunch
    var projectStart: URL?
  }

  /// Unit for the repeat stepper. Seconds are offered because a "nudge the
  /// agent every 30 s" watchdog is a real use, but the runner's settle window
  /// still throttles anything shorter than a few seconds.
  enum IntervalUnit: String, CaseIterable, Equatable, Sendable {
    case seconds
    case minutes
    case hours

    var seconds: TimeInterval {
      switch self {
      case .seconds: return 1
      case .minutes: return 60
      case .hours: return 3600
      }
    }

    var title: String {
      switch self {
      case .seconds: return "seconds"
      case .minutes: return "minutes"
      case .hours: return "hours"
      }
    }
  }

  enum Action: Equatable {
    /// Follows the pane, so the skills follow its agent and directory.
    case onAppear
    case paneChanged(Pane?)
    case draftChanged(String)
    /// Picked files, and the editor's caret or selection as UTF-16 offsets
    /// (`nil` appends to the end).
    case filesSelected([URL], selection: Range<Int>?)
    case modeChanged(State.Mode)
    case scheduledAtChanged(Date)
    case repeatEnabledChanged(Bool)
    case repeatAmountChanged(Int)
    case repeatUnitChanged(IntervalUnit)
    /// Commit the draft under the selected mode.
    case submitted
    case skillsLoaded([AgentSkillEntry], for: SkillScope)
    /// The Skills button: put the call prefix at the draft's caret or
    /// selection (UTF-16 offsets, `nil` appends to the end).
    case skillsButtonTapped(selection: Range<Int>?)
    case delegate(Delegate)
    case removeTapped(QueuedCommand.ID)
    case clearAllTapped

    enum Delegate: Equatable {
      case submitted
    }
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(AgentSkillClient.self) private var agentSkillClient
  @Dependency(\.date) private var date

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        let paneID = state.paneID
        let client = hierarchyClient
        return .run { send in
          for await pane in await client.paneChanges(paneID) {
            await send(.paneChanged(pane))
          }
        }
        .cancellable(id: CancelID.pane, cancelInFlight: true)

      case .paneChanged(let pane):
        return updateSkills(for: pane, state: &state)

      case .skillsLoaded(let skills, let scope):
        // A scan for an agent or directory the pane no longer has is dropped.
        guard scope == state.skillsScope else { return .none }
        state.skills = skills
        return .none

      case .skillsButtonTapped(let selection):
        let location = state.skillLocation
        guard state.skillsUnavailableReason == nil, let prefix = location.invocationStyle.prefix,
          let result = ComposerSkillCompletion.insertingPrefix(
            prefix, into: state.draft, selection: selection, position: location.invocationPosition)
        else { return .none }
        state.draft = result.text
        return .none

      case .draftChanged(let text):
        state.draft = text
        return .none

      case .filesSelected(let urls, let selection):
        if let result = ComposerPathInsertion.insert(urls, into: state.draft, selection: selection) {
          state.draft = result.text
        }
        return .none

      case .modeChanged(let mode):
        state.mode = mode
        // Re-seed the picker each time the user lands on Schedule: a panel
        // left open for an hour would otherwise offer a time already past.
        if mode == .scheduled, state.scheduledAt <= date.now {
          state.scheduledAt = State.defaultScheduleDate(from: date.now)
        }
        return .none

      case .scheduledAtChanged(let value):
        state.scheduledAt = value
        return .none

      case .repeatEnabledChanged(let value):
        state.repeatEnabled = value
        return .none

      case .repeatAmountChanged(let value):
        state.repeatAmount = max(1, value)
        return .none

      case .repeatUnitChanged(let unit):
        state.repeatUnit = unit
        return .none

      case .submitted:
        let text = state.trimmedDraft
        guard !text.isEmpty else { return .none }
        let paneID = state.paneID
        switch state.mode {
        case .now:
          // Never enters the queue — it is already delivered. The panel is
          // always opened on a pane the user is looking at, so a live
          // surface is a given here. `sendCommand` (not `sendInput`) so the
          // body lands as one paste and the Return arrives as its own
          // keypress; see its docstring.
          terminalClient.sendCommand(paneID, text)
        case .afterCurrentTask:
          append(.init(text: text, timing: .afterCurrentTask, createdAt: date.now), to: paneID)
        case .scheduled:
          append(
            .init(
              text: text,
              timing: .scheduled(at: state.scheduledAt, repeatEvery: state.repeatInterval),
              createdAt: date.now,
            ),
            to: paneID,
          )
        }
        state.draft = ""
        return .send(.delegate(.submitted))

      case .delegate:
        return .none

      case .removeTapped(let id):
        let queue = hierarchyClient.commandQueue(state.paneID)
        hierarchyClient.setCommandQueue(state.paneID, queue.filter { $0.id != id })
        return .none

      case .clearAllTapped:
        hierarchyClient.setCommandQueue(state.paneID, [])
        return .none
      }
    }
  }

  private nonisolated enum CancelID { case pane, skills }

  /// Reads the skills of the agent that runs in the pane as that agent
  /// resolves them: its argv and environment (home, config root, launch
  /// flags) come from the running process, and project skills are searched
  /// from its current directory (ADR 0010). A launch codans cannot read
  /// offers no skills. A new agent or directory drops the old skills at
  /// once.
  private func updateSkills(for pane: Pane?, state: inout State) -> Effect<Action> {
    guard let pane, let kind = pane.agentKind else {
      return clearSkills(reason: State.noAgentReason, state: &state)
    }
    let descriptor = AgentCatalog.descriptor(for: kind)
    let catalog = hierarchyClient.snapshot()
    let isRemote =
      catalog.projectID(forPane: pane.id)
      .flatMap { id in catalog.projects.first { $0.id == id } }?.isRemote ?? false
    if let reason = ComposerSkillCompletion.unavailableReason(for: descriptor, isRemote: isRemote) {
      return clearSkills(reason: reason, state: &state)
    }
    guard let agent = terminalClient.runningAgent(pane.id, kind), let launch = agent.launch else {
      return clearSkills(reason: State.unreadableLaunchReason, state: &state)
    }
    let projectStart =
      agent.workingDirectory
      ?? (pane.workingDirectory.isEmpty ? nil : URL(fileURLWithPath: pane.workingDirectory, isDirectory: true))
    let scope = SkillScope(pid: agent.pid, launch: launch, projectStart: projectStart)
    state.skillLocation = descriptor.skillLocation
    state.skillsUnavailableReason = nil
    guard scope != state.skillsScope else { return .none }
    state.skills = []
    state.skillsScope = scope
    let client = agentSkillClient
    return .run { send in
      await send(.skillsLoaded(client.load(launch, projectStart, nil), for: scope))
    }
    .cancellable(id: CancelID.skills, cancelInFlight: true)
  }

  private func clearSkills(reason: String, state: inout State) -> Effect<Action> {
    state.skillLocation = .none
    state.skills = []
    state.skillsScope = nil
    state.skillsUnavailableReason = reason
    return .cancel(id: CancelID.skills)
  }

  /// Read-modify-write against the live catalog rather than a snapshot: the
  /// runner can drain an entry between the panel opening and this append.
  private func append(_ command: QueuedCommand, to paneID: PaneID) {
    var queue = hierarchyClient.commandQueue(paneID)
    queue.append(command)
    hierarchyClient.setCommandQueue(paneID, queue)
  }
}
