import CodansCore
import Foundation
import Observation

/// Presentation-only coalescing of one row's agent title. A change after
/// a quiet period is delivered at once and opens a window of `interval`;
/// later changes in the window coalesce, and the latest value is delivered
/// when the window ends (which opens the next window). Agents that retitle
/// their pane many times per second so redraw the row at most once per
/// `interval`, and the row always ends on the latest value. The text never
/// drives runtime state, `lastTransitionAt`, or row order.
@MainActor
@Observable
final class AgentTitlePresentation {
  static let defaultInterval: Duration = .milliseconds(250)

  /// The delivered agent title, or nil when the agent reports nothing
  /// beyond its own name.
  private(set) var text: String?

  @ObservationIgnored private var latestText: String?
  /// Non-nil while a coalescing window is open.
  @ObservationIgnored private var window: Task<Void, Never>?
  private let interval: Duration
  private let kind: AgentKind

  init(kind: AgentKind, interval: Duration = defaultInterval) {
    self.kind = kind
    self.interval = interval
  }

  // Keep teardown synchronous when SwiftUI destroys the row's state.
  deinit {
    window?.cancel()
  }

  /// The row's first line: the agent title, else the agent display name.
  var rowText: String { text ?? kind.displayName }

  func update(title: String?) {
    latestText = AgentTitleFormat.titleLine(from: title, kind: kind)
    guard window == nil, latestText != text else { return }
    text = latestText
    openWindow()
  }

  func cancel() {
    window?.cancel()
    window = nil
    latestText = text
  }

  /// Waits until the open window, and any window its delivery opens, ends.
  func awaitPendingUpdateForTests() async {
    await window?.value
  }

  private func openWindow() {
    let delay = interval
    window = Task { @MainActor [weak self] in
      while true {
        do {
          try await Task.sleep(for: delay)
        } catch {
          return
        }
        guard !Task.isCancelled, let self else { return }
        guard self.latestText != self.text else {
          self.window = nil
          return
        }
        self.text = self.latestText
      }
    }
  }
}
