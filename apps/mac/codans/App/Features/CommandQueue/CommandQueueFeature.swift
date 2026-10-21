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
    var id: ContentID { contentID }

    /// Pane the panel is editing. Fixed for the presentation's lifetime —
    /// re-opening on another pane replaces the whole state.
    let contentID: ContentID
    var draft: String = ""
    var mode: Mode = .afterCurrentTask
    /// First (or only) fire time for `.scheduled`. Seeded a few minutes out
    /// so the date picker opens on a plausible value rather than "now",
    /// which would fire before the user finishes typing.
    var scheduledAt: Date
    var repeatEnabled: Bool = false
    var repeatAmount: Int = 30
    var repeatUnit: IntervalUnit = .minutes

    init(contentID: ContentID, now: Date = Date()) {
      self.contentID = contentID
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
    case draftChanged(String)
    case filesSelected([URL])
    case modeChanged(State.Mode)
    case scheduledAtChanged(Date)
    case repeatEnabledChanged(Bool)
    case repeatAmountChanged(Int)
    case repeatUnitChanged(IntervalUnit)
    /// Commit the draft under the selected mode.
    case submitted
    case delegate(Delegate)
    case removeTapped(QueuedCommand.ID)
    case clearAllTapped

    enum Delegate: Equatable {
      case submitted
    }
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(\.date) private var date

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .draftChanged(let text):
        state.draft = text
        return .none

      case .filesSelected(let urls):
        let paths = urls.filter(\.isFileURL)
          .map { ShellQuoting.quoted($0.path(percentEncoded: false)) }
          .joined(separator: " ")
        guard !paths.isEmpty else { return .none }
        if let last = state.draft.last, !last.isWhitespace {
          state.draft += " "
        }
        state.draft += paths
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
        let contentID = state.contentID
        switch state.mode {
        case .now:
          // Never enters the queue — it is already delivered. The panel is
          // always opened on a pane the user is looking at, so a live
          // surface is a given here. `sendCommand` (not `sendInput`) so the
          // body lands as one paste and the Return arrives as its own
          // keypress; see its docstring.
          terminalClient.sendCommand(contentID, text)
        case .afterCurrentTask:
          append(.init(text: text, timing: .afterCurrentTask, createdAt: date.now), to: contentID)
        case .scheduled:
          append(
            .init(
              text: text,
              timing: .scheduled(at: state.scheduledAt, repeatEvery: state.repeatInterval),
              createdAt: date.now,
            ),
            to: contentID,
          )
        }
        state.draft = ""
        return .send(.delegate(.submitted))

      case .delegate:
        return .none

      case .removeTapped(let id):
        let queue = hierarchyClient.commandQueue(state.contentID)
        hierarchyClient.setCommandQueue(state.contentID, queue.filter { $0.id != id })
        return .none

      case .clearAllTapped:
        hierarchyClient.setCommandQueue(state.contentID, [])
        return .none
      }
    }
  }

  /// Read-modify-write against the live catalog rather than a snapshot: the
  /// runner can drain an entry between the panel opening and this append.
  private func append(_ command: QueuedCommand, to contentID: ContentID) {
    var queue = hierarchyClient.commandQueue(contentID)
    queue.append(command)
    hierarchyClient.setCommandQueue(contentID, queue)
  }
}
