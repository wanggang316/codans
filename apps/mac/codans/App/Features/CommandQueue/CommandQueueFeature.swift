import CodansCore
import ComposableArchitecture
import Foundation

/// Editor state for the Command Queue panel (⌘⌥L).
///
/// Only the *draft* lives here. The queue itself is catalog state
/// (`Pane.commandQueue`) and the panel reads it straight off the
/// `@Observable` `HierarchyManager`, so a command draining while the panel is
/// open disappears from the list without a reducer round-trip. That split is
/// the documented hybrid boundary: terminal / hierarchy state is
/// `@Observable`, app flow state is TCA.
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
    /// entry (see `QueuedCommandTiming`).
    enum Mode: String, CaseIterable, Equatable {
      case now
      case afterCurrentTask
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
    case modeChanged(State.Mode)
    case scheduledAtChanged(Date)
    case repeatEnabledChanged(Bool)
    case repeatAmountChanged(Int)
    case repeatUnitChanged(IntervalUnit)
    /// Commit the draft under the selected mode.
    case submitted
    case removeTapped(QueuedCommand.ID)
    case clearAllTapped
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
          // Return arrives as its own keypress; see its docstring.
          terminalClient.sendCommand(paneID, text)
        case .afterCurrentTask:
          append(.init(text: text, timing: .afterCurrentTask, createdAt: date.now), to: paneID)
        case .scheduled:
          append(
            .init(
              text: text,
              timing: .scheduled(at: state.scheduledAt, repeatEvery: state.repeatInterval),
              createdAt: date.now
            ),
            to: paneID
          )
        }
        state.draft = ""
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

  /// Read-modify-write against the live catalog rather than a snapshot: the
  /// runner can drain an entry between the panel opening and this append.
  private func append(_ command: QueuedCommand, to paneID: PaneID) {
    var queue = hierarchyClient.commandQueue(paneID)
    queue.append(command)
    hierarchyClient.setCommandQueue(paneID, queue)
  }
}
