import AppKit
import CodansCore
import SwiftUI
import Testing

@testable import Codans

@MainActor
struct AgentActivityPresentationTests {
  @Test
  func burstsDeliverLatestTitleWithoutRestartingTheWindow() async {
    let activity = AgentActivityPresentation(title: "Reading", kind: .codex, interval: .zero)
    activity.update(title: "Editing")
    activity.update(title: "Running tests")
    #expect(activity.text == "Reading")
    await activity.awaitPendingUpdateForTests()
    #expect(activity.text == "Running tests")

    activity.update(title: "Reviewing")
    await activity.awaitPendingUpdateForTests()
    #expect(activity.text == "Reviewing")
  }

  @Test
  func emptyAndRedundantTitlesClearPreviousActivity() async {
    let activity = AgentActivityPresentation(title: "Reading", kind: .claudeCode, interval: .zero)
    for title: String? in [nil, "   ", "✳ Claude Code"] {
      activity.update(title: "  Running tests  ")
      await activity.awaitPendingUpdateForTests()
      #expect(activity.text == "Running tests")
      activity.update(title: title)
      await activity.awaitPendingUpdateForTests()
      #expect(activity.text == nil)
    }
  }

  @Test
  func cancelDoesNotDeliverOldTitleIntoNewPresentation() async {
    let activity = AgentActivityPresentation(title: "Reading", kind: .codex, interval: .zero)
    activity.update(title: "Stale")
    activity.cancel()
    activity.update(title: "Current")
    await activity.awaitPendingUpdateForTests()
    #expect(activity.text == "Current")
  }

  @Test
  func separatePanesHaveIndependentActivity() async {
    let first = AgentActivityPresentation(title: "Reading", kind: .codex, interval: .zero)
    let second = AgentActivityPresentation(title: "Editing", kind: .codex, interval: .zero)
    first.update(title: "Testing")
    await first.awaitPendingUpdateForTests()
    #expect(first.text == "Testing")
    #expect(second.text == "Editing")
  }

  @Test
  func pendingUpdateDoesNotRetainDismissedPresentation() {
    var activity: AgentActivityPresentation? = AgentActivityPresentation(title: "Reading", kind: .codex)
    weak var released = activity
    activity?.update(title: "Testing")
    activity = nil
    #expect(released == nil)
  }

  @Test
  func mountedActivityTracksPaneTitlesWithoutResizing() async throws {
    let paneID = PaneID()
    let registry = AgentStateStore(focusedPane: { nil })
    registry.onAgentBound(paneID, kind: .codex, sessionID: nil)
    let entry = registry.entries[paneID]
    let activity = AgentActivityPresentation(title: nil, kind: .codex, interval: .zero)
    let host = NSHostingView(
      rootView: AgentSessionActivityLine(paneTitle: { registry.title(for: paneID) }, activity: activity)
        .frame(width: 296)
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 296, height: 16),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = host
    defer {
      activity.cancel()
      window.contentView = nil
    }
    host.layoutSubtreeIfNeeded()
    let initialSize = host.fittingSize
    #expect(initialSize == NSSize(width: 296, height: 16))

    for title in ["Running tests", String(repeating: "Long activity ", count: 30), "Codex"] {
      registry.onTerminalEvent(.paneInfoChanged(paneID, .title(title)))
      let expected = AgentSummaryCardFormat.activityLine(from: title, kind: .codex)
      // Give the mounted SwiftUI observation graph a display turn; do not
      // replace rootView, which would hide a broken live subscription.
      let deadline = ContinuousClock.now + .seconds(2)
      while activity.text != expected, ContinuousClock.now < deadline {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(activity.text == expected)
      #expect(host.fittingSize == initialSize)
      #expect(registry.entries[paneID] == entry)
    }
  }

  @Test(arguments: [false, true])
  func cardSizeDoesNotDependOnActivity(hasSession: Bool) {
    let session =
      hasSession
      ? AgentSessionSummary(agent: .codex, sessionID: "test", title: "Investigate a failure", updatedAt: .now)
      : nil
    let sizes = [nil, "Reading", String(repeating: "A long activity title ", count: 30), "✳ Codex"].map { title in
      let snapshot = AgentSessionSummarySnapshot(
        paneID: PaneID(),
        entry: .init(kind: .codex, sessionID: nil, state: .working, lastTransitionAt: .now),
        projectName: "Project", worktreeName: "main", projectColor: nil,
        session: session, paneTitle: title
      )
      let host = NSHostingView(rootView: AgentSessionSummaryCard(snapshot: snapshot, paneTitle: { title }))
      return host.fittingSize
    }
    #expect(sizes[0].width == 320)
    #expect(sizes[0].height > 0)
    #expect(sizes.allSatisfy { $0 == sizes[0] })
  }
}
