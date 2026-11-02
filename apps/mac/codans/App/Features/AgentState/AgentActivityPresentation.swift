import CodansCore
import Foundation
import Observation

/// Presentation-only coalescing of one row's activity text. Agents retitle
/// their pane many times per second; the row shows at most one change per
/// `interval`, and always the latest value. The text never drives runtime
/// state, `lastTransitionAt`, or row order.
@MainActor
@Observable
final class AgentActivityPresentation {
  /// The delivered activity text, or nil when the agent reports nothing
  /// beyond its own name.
  private(set) var text: String?

  @ObservationIgnored private var latestText: String?
  @ObservationIgnored private var pendingUpdate: Task<Void, Never>?
  /// False until the first value arrives. The first value is delivered at
  /// once, so a row that appears does not show the agent name for a
  /// window before its activity.
  @ObservationIgnored private var hasDelivered = false
  private let interval: Duration
  private let kind: AgentKind

  init(kind: AgentKind, interval: Duration = .seconds(1)) {
    self.kind = kind
    self.interval = interval
  }

  // Keep teardown synchronous when SwiftUI destroys the row's state.
  deinit {
    pendingUpdate?.cancel()
  }

  /// The row's first line: the activity text, else the agent display name.
  var rowText: String { text ?? kind.displayName }

  func update(activity: String?) {
    latestText = AgentActivityFormat.activityLine(from: activity, kind: kind)
    guard hasDelivered else {
      hasDelivered = true
      text = latestText
      return
    }
    guard pendingUpdate == nil, latestText != text else { return }
    let delay = interval
    pendingUpdate = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard !Task.isCancelled, let self else { return }
      self.text = self.latestText
      self.pendingUpdate = nil
    }
  }

  func cancel() {
    pendingUpdate?.cancel()
    pendingUpdate = nil
    latestText = text
  }

  func awaitPendingUpdateForTests() async {
    await pendingUpdate?.value
  }
}
