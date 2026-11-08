import AppKit
import CodansCore
import SwiftUI
import Testing

@testable import Codans

@MainActor
struct AgentTitlePresentationTests {
  @Test
  func firstValueIsDeliveredWithoutWaiting() {
    let presentation = AgentTitlePresentation(kind: .codex, interval: .seconds(60))
    #expect(presentation.text == nil)
    #expect(presentation.rowText == AgentKind.codex.displayName)
    presentation.update(title: "Reading")
    #expect(presentation.text == "Reading")
    #expect(presentation.rowText == "Reading")
  }

  @Test
  func defaultWindowIsQuarterSecond() {
    #expect(AgentTitlePresentation.defaultInterval == .milliseconds(250))
  }

  @Test
  func singleChangeAfterQuietPeriodIsDeliveredAtOnce() async {
    let presentation = AgentTitlePresentation(kind: .codex, interval: .zero)
    presentation.update(title: "Reading")
    await presentation.awaitPendingUpdateForTests()
    presentation.update(title: "Editing")
    #expect(presentation.text == "Editing")
  }

  @Test
  func leadingChangeOpensWindowThatDeliversLatestAtItsEnd() async throws {
    let presentation = AgentTitlePresentation(kind: .codex, interval: .milliseconds(200))
    presentation.update(title: "Reading")
    try await Task.sleep(for: .milliseconds(300))
    presentation.update(title: "Editing")
    #expect(presentation.text == "Editing")
    presentation.update(title: "Testing")
    presentation.update(title: "Reviewing")
    #expect(presentation.text == "Editing")
    await presentation.awaitPendingUpdateForTests()
    #expect(presentation.text == "Reviewing")
  }

  @Test
  func deliveryAtWindowEndOpensNextWindow() async throws {
    let presentation = AgentTitlePresentation(kind: .codex, interval: .milliseconds(200))
    presentation.update(title: "Reading")
    presentation.update(title: "Editing")
    // The first window ends near 200 ms and delivers "Editing"; that
    // delivery opens a second window, so a change at 300 ms waits.
    try await Task.sleep(for: .milliseconds(300))
    #expect(presentation.text == "Editing")
    presentation.update(title: "Testing")
    #expect(presentation.text == "Editing")
    await presentation.awaitPendingUpdateForTests()
    #expect(presentation.text == "Testing")
  }

  @Test
  func burstsDeliverLatestTextWithoutRestartingTheWindow() async {
    let presentation = AgentTitlePresentation(kind: .codex, interval: .zero)
    presentation.update(title: "Reading")
    presentation.update(title: "Editing")
    presentation.update(title: "Running tests")
    #expect(presentation.text == "Reading")
    await presentation.awaitPendingUpdateForTests()
    #expect(presentation.text == "Running tests")

    presentation.update(title: "Reviewing")
    await presentation.awaitPendingUpdateForTests()
    #expect(presentation.text == "Reviewing")
  }

  @Test
  func updatesInsideTheWindowAreHeldBack() async throws {
    let presentation = AgentTitlePresentation(kind: .codex, interval: .milliseconds(200))
    presentation.update(title: "Reading")
    presentation.update(title: "Editing")
    try await Task.sleep(for: .milliseconds(50))
    presentation.update(title: "Testing")
    #expect(presentation.text == "Reading")
    await presentation.awaitPendingUpdateForTests()
    #expect(presentation.text == "Testing")
  }

  @Test
  func emptyAndRedundantTextFallsBackToAgentName() async {
    let presentation = AgentTitlePresentation(kind: .claudeCode, interval: .zero)
    presentation.update(title: "Reading")
    for text: String? in [nil, "   ", "✳ Claude Code"] {
      presentation.update(title: "  Running tests  ")
      await presentation.awaitPendingUpdateForTests()
      #expect(presentation.rowText == "Running tests")
      presentation.update(title: text)
      await presentation.awaitPendingUpdateForTests()
      #expect(presentation.text == nil)
      #expect(presentation.rowText == AgentKind.claudeCode.displayName)
    }
  }

  @Test
  func cancelDoesNotDeliverStaleText() async {
    let presentation = AgentTitlePresentation(kind: .codex, interval: .zero)
    presentation.update(title: "Reading")
    presentation.update(title: "Stale")
    presentation.cancel()
    presentation.update(title: "Current")
    await presentation.awaitPendingUpdateForTests()
    #expect(presentation.text == "Current")
  }

  @Test
  func separatePanesHaveIndependentActivity() async {
    let first = AgentTitlePresentation(kind: .codex, interval: .zero)
    let second = AgentTitlePresentation(kind: .codex, interval: .zero)
    first.update(title: "Reading")
    second.update(title: "Editing")
    first.update(title: "Testing")
    await first.awaitPendingUpdateForTests()
    #expect(first.text == "Testing")
    #expect(second.text == "Editing")
  }

  @Test
  func pendingUpdateDoesNotRetainReleasedPresentation() {
    var presentation: AgentTitlePresentation? = AgentTitlePresentation(kind: .codex)
    weak var released = presentation
    presentation?.update(title: "Reading")
    presentation?.update(title: "Testing")
    presentation = nil
    #expect(released == nil)
  }

  @Test
  func mountedLineTracksActivityWithoutResizingOrChangingState() async throws {
    let paneID = PaneID()
    let registry = AgentStateStore(focusedPane: { nil })
    registry.onAgentBound(paneID, kind: .codex, sessionID: nil)
    let entry = registry.entries[paneID]
    let presentation = AgentTitlePresentation(kind: .codex, interval: .zero)
    let host = NSHostingView(
      rootView: AgentTitleLine(
        paneID: paneID,
        agentTitle: { registry.agentTitle(for: paneID) },
        presentation: presentation
      )
      .frame(width: 240)
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = host
    defer {
      presentation.cancel()
      window.contentView = nil
    }
    host.layoutSubtreeIfNeeded()
    let initialSize = host.fittingSize
    #expect(initialSize.height > 0)
    #expect(presentation.rowText == AgentKind.codex.displayName)

    for title in ["Running tests", String(repeating: "Long presentation ", count: 30), "Codex"] {
      registry.onTerminalEvent(.paneInfoChanged(paneID, .title(title)))
      let expected = AgentTitleFormat.rowText(from: title, kind: .codex)
      // Give the mounted SwiftUI observation graph a display turn; do not
      // replace rootView, which would hide a broken live subscription.
      let deadline = ContinuousClock.now + .seconds(2)
      while presentation.rowText != expected, ContinuousClock.now < deadline {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(presentation.rowText == expected)
      #expect(host.fittingSize == initialSize)
      #expect(registry.entries[paneID] == entry)
    }
  }
}
