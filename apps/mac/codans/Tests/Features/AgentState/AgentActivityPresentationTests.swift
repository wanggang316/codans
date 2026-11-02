import AppKit
import CodansCore
import SwiftUI
import Testing

@testable import Codans

@MainActor
struct AgentActivityPresentationTests {
  @Test
  func firstValueIsDeliveredWithoutWaiting() {
    let activity = AgentActivityPresentation(kind: .codex, interval: .seconds(60))
    #expect(activity.text == nil)
    #expect(activity.rowText == AgentKind.codex.displayName)
    activity.update(activity: "Reading")
    #expect(activity.text == "Reading")
    #expect(activity.rowText == "Reading")
  }

  @Test
  func burstsDeliverLatestTextWithoutRestartingTheWindow() async {
    let activity = AgentActivityPresentation(kind: .codex, interval: .zero)
    activity.update(activity: "Reading")
    activity.update(activity: "Editing")
    activity.update(activity: "Running tests")
    #expect(activity.text == "Reading")
    await activity.awaitPendingUpdateForTests()
    #expect(activity.text == "Running tests")

    activity.update(activity: "Reviewing")
    await activity.awaitPendingUpdateForTests()
    #expect(activity.text == "Reviewing")
  }

  @Test
  func updatesInsideTheWindowAreHeldBack() async throws {
    let activity = AgentActivityPresentation(kind: .codex, interval: .milliseconds(200))
    activity.update(activity: "Reading")
    activity.update(activity: "Editing")
    try await Task.sleep(for: .milliseconds(50))
    activity.update(activity: "Testing")
    #expect(activity.text == "Reading")
    await activity.awaitPendingUpdateForTests()
    #expect(activity.text == "Testing")
  }

  @Test
  func emptyAndRedundantTextFallsBackToAgentName() async {
    let activity = AgentActivityPresentation(kind: .claudeCode, interval: .zero)
    activity.update(activity: "Reading")
    for text: String? in [nil, "   ", "✳ Claude Code"] {
      activity.update(activity: "  Running tests  ")
      await activity.awaitPendingUpdateForTests()
      #expect(activity.rowText == "Running tests")
      activity.update(activity: text)
      await activity.awaitPendingUpdateForTests()
      #expect(activity.text == nil)
      #expect(activity.rowText == AgentKind.claudeCode.displayName)
    }
  }

  @Test
  func cancelDoesNotDeliverStaleText() async {
    let activity = AgentActivityPresentation(kind: .codex, interval: .zero)
    activity.update(activity: "Reading")
    activity.update(activity: "Stale")
    activity.cancel()
    activity.update(activity: "Current")
    await activity.awaitPendingUpdateForTests()
    #expect(activity.text == "Current")
  }

  @Test
  func separatePanesHaveIndependentActivity() async {
    let first = AgentActivityPresentation(kind: .codex, interval: .zero)
    let second = AgentActivityPresentation(kind: .codex, interval: .zero)
    first.update(activity: "Reading")
    second.update(activity: "Editing")
    first.update(activity: "Testing")
    await first.awaitPendingUpdateForTests()
    #expect(first.text == "Testing")
    #expect(second.text == "Editing")
  }

  @Test
  func pendingUpdateDoesNotRetainReleasedPresentation() {
    var activity: AgentActivityPresentation? = AgentActivityPresentation(kind: .codex)
    weak var released = activity
    activity?.update(activity: "Reading")
    activity?.update(activity: "Testing")
    activity = nil
    #expect(released == nil)
  }

  @Test
  func mountedLineTracksActivityWithoutResizingOrChangingState() async throws {
    let paneID = PaneID()
    let registry = AgentStateStore(focusedPane: { nil })
    registry.onAgentBound(paneID, kind: .codex, sessionID: nil)
    let entry = registry.entries[paneID]
    let activity = AgentActivityPresentation(kind: .codex, interval: .zero)
    let host = NSHostingView(
      rootView: AgentActivityLine(
        paneID: paneID,
        activityText: { registry.activityText(for: paneID) },
        activity: activity
      )
      .frame(width: 240)
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = host
    defer {
      activity.cancel()
      window.contentView = nil
    }
    host.layoutSubtreeIfNeeded()
    let initialSize = host.fittingSize
    #expect(initialSize.height > 0)
    #expect(activity.rowText == AgentKind.codex.displayName)

    for title in ["Running tests", String(repeating: "Long activity ", count: 30), "Codex"] {
      registry.onTerminalEvent(.paneInfoChanged(paneID, .title(title)))
      let expected = AgentActivityFormat.rowText(from: title, kind: .codex)
      // Give the mounted SwiftUI observation graph a display turn; do not
      // replace rootView, which would hide a broken live subscription.
      let deadline = ContinuousClock.now + .seconds(2)
      while activity.rowText != expected, ContinuousClock.now < deadline {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(activity.rowText == expected)
      #expect(host.fittingSize == initialSize)
      #expect(registry.entries[paneID] == entry)
    }
  }
}
