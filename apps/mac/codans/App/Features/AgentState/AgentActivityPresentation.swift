import CodansCore
import Foundation
import Observation

/// Presentation-only coalescing: title animations must not drive runtime
/// transitions, row ordering, or a resize of the summary popover.
@MainActor
@Observable
final class AgentActivityPresentation {
  private(set) var text: String?

  @ObservationIgnored private var latestText: String?
  @ObservationIgnored private var pendingUpdate: Task<Void, Never>?
  private let interval: Duration
  private let kind: AgentKind

  init(title: String?, kind: AgentKind, interval: Duration = .seconds(1)) {
    self.kind = kind
    self.interval = interval
    self.text = AgentSummaryCardFormat.activityLine(from: title, kind: kind)
    self.latestText = text
  }

  // Keep teardown synchronous when SwiftUI destroys the popover's state.
  deinit {
    pendingUpdate?.cancel()
  }

  func update(title: String?) {
    latestText = AgentSummaryCardFormat.activityLine(from: title, kind: kind)
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
