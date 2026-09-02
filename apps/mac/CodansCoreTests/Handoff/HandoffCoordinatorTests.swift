import Foundation
import Testing

@testable import CodansCore

/// The transition sequence every entry point shares. Asserted against real
/// files so "archive before rewrite" and "current.md exists iff a briefing
/// produced it" are proven, not described.
struct HandoffCoordinatorTests {
  private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)
  private static let briefing = "# Handoff\n## Objective\na\n## Current State\nb\n## Next Steps\nc\n"

  private static func makeCoordinator() throws -> HandoffCoordinator {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "HandoffCoordinatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return HandoffCoordinator(store: HandoffStore(rootURL: root))
  }

  private static func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  @Test
  func transitionWithBriefingArchivesThePreviousRoundAndInstallsTheNewOne() throws {
    let coordinator = try Self.makeCoordinator()
    let store = coordinator.store
    try store.writeBriefing("# old\n", archivingPrevious: false, now: Self.stamp)

    let result = try coordinator.transition(
      outgoing: .claudeCode,
      to: .codex,
      session: HandoffSessionContext(agentKind: .claudeCode, sessionID: "s1", paneID: "p1"),
      repo: HandoffRepoState(branch: "main"),
      briefing: try HandoffPreparedBriefing(source: .inline(Self.briefing)),
      now: Self.stamp
    )
    #expect(result.hasBriefing)
    #expect(result.archivedPath == "handoff/archive/20231114-221320-claude-code-to-codex.md")
    #expect(result.session?.resumeCommand == "claude --resume 's1'")
    #expect(try Self.read(store.currentURL) == Self.briefing)
    #expect(try Self.read(store.stateDirectory.appending(path: result.archivedPath!)).hasPrefix("# old"))
    #expect(try Self.read(store.contextURL).contains("- Branch: main"))
  }

  @Test
  func contextOnlyTransitionRemovesTheStaleBriefing() throws {
    let coordinator = try Self.makeCoordinator()
    let store = coordinator.store
    try store.writeBriefing("# old\n", archivingPrevious: false, now: Self.stamp)

    let result = try coordinator.transition(
      outgoing: nil, to: .codex, session: nil, repo: .notGit,
      briefing: .contextOnly, now: Self.stamp
    )
    #expect(!result.hasBriefing)
    #expect(result.archivedPath == "handoff/archive/20231114-221320-agent-to-codex.md")
    #expect(!store.hasCurrentBriefing)
    #expect(result.session == nil)
  }

  @Test
  func checkpointKeepsAnEarlierBriefingWhenNoneIsSupplied() throws {
    let coordinator = try Self.makeCoordinator()
    let store = coordinator.store
    try store.writeBriefing("# keep me\n", archivingPrevious: false, now: Self.stamp)

    let result = try coordinator.checkpoint(
      outgoing: .codex, session: nil, repo: HandoffRepoState(changedFiles: ["x"]),
      briefing: .contextOnly, note: "eod", now: Self.stamp
    )
    #expect(result.briefing == .none)
    #expect(try Self.read(store.currentURL) == "# keep me\n")
    #expect(try Self.read(store.logURL).contains("save  agent=codex  changed=1  briefing=none  note=\"eod\""))
  }

  @Test
  func checkpointWithBriefingArchivesTheReplacedOne() throws {
    let coordinator = try Self.makeCoordinator()
    let store = coordinator.store
    try store.writeBriefing("# old\n", archivingPrevious: false, now: Self.stamp)

    _ = try coordinator.checkpoint(
      outgoing: .codex, session: nil, repo: .notGit,
      briefing: try HandoffPreparedBriefing(source: .inline(Self.briefing)), note: nil, now: Self.stamp
    )
    #expect(try Self.read(store.currentURL) == Self.briefing)
    let archived = try FileManager.default.contentsOfDirectory(
      atPath: store.archiveDirectory.path(percentEncoded: false))
    #expect(archived == ["20231114-221320-replaced-current.md"])
  }

  @Test
  func transitionLogLineCoversEveryDisposition() {
    #expect(
      HandoffCoordinator.transitionLogLine(
        from: .claudeCode, to: .codex, disposition: .pane("p9"), briefing: .inline,
        archivedPath: nil, note: nil, source: nil)
        == "claude-code -> codex  pane=p9  briefing=inline")
    #expect(
      HandoffCoordinator.transitionLogLine(
        from: nil, to: .codex, disposition: .skipped, briefing: .none,
        archivedPath: nil, note: " hi\nthere ", source: "hud")
        == "agent -> codex  (no launch)  briefing=none  source=hud  note=\"hi\nthere\"".replacingOccurrences(
          of: "hi\nthere", with: "hi there"))
    #expect(
      HandoffCoordinator.transitionLogLine(
        from: .codex, to: .claudeCode, disposition: .failed, briefing: .inline,
        archivedPath: "handoff/archive/x.md", note: nil, source: nil)
        == "codex -> claude-code  launch=failed  briefing=inline  archive=handoff/archive/x.md")
  }
}
