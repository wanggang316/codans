import Foundation
import Testing

@testable import CodansCore

/// Filesystem contract of the `.codans/handoff/` artifact. Every test works
/// in a fresh temporary root so the invariants (archive before rewrite,
/// self-ignoring directory, stable naming) are asserted against real files.
struct HandoffStoreTests {
  private static func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "HandoffStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14T22:13:20Z

  private static func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  @Test
  func ensureLayoutCreatesASelfIgnoringTree() throws {
    let store = HandoffStore(rootURL: try Self.makeRoot())
    try store.ensureLayout()
    #expect(FileManager.default.fileExists(atPath: store.archiveDirectory.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: store.sessionsDirectory.path(percentEncoded: false)))
    #expect(try Self.read(store.ignoreURL) == "*\n")
    #expect(!store.hasCurrentBriefing)
    // Directory URLs render with a trailing slash; strip it before matching.
    let handoffPath = store.handoffDirectory.path(percentEncoded: false)
    #expect(handoffPath.hasSuffix("/.codans/handoff/"))
  }

  @Test
  func writeBriefingArchivesTheReplacedOneWhenAsked() throws {
    let store = HandoffStore(rootURL: try Self.makeRoot())
    try store.writeBriefing("# one\n", archivingPrevious: true, now: Self.stamp)
    // First write: nothing to archive.
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: store.archiveDirectory.path(percentEncoded: false)).isEmpty)

    try store.writeBriefing("# two\n", archivingPrevious: true, now: Self.stamp)
    #expect(try Self.read(store.currentURL) == "# two\n")
    let archived = try FileManager.default.contentsOfDirectory(
      atPath: store.archiveDirectory.path(percentEncoded: false))
    #expect(archived == ["20231114-221320-replaced-current.md"])
    #expect(try Self.read(store.archiveDirectory.appending(path: archived[0])) == "# one\n")

    // A transition passes `false` because it archived the combined snapshot already.
    try store.writeBriefing("# three\n", archivingPrevious: false, now: Self.stamp)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: store.archiveDirectory.path(percentEncoded: false)).count == 1
    )
  }

  @Test
  func archiveCurrentCombinesBriefingAndContextAndReturnsARelativePath() throws {
    let store = HandoffStore(rootURL: try Self.makeRoot())
    #expect(try store.archiveCurrent(from: "claude-code", to: "codex", now: Self.stamp) == nil)

    try store.writeBriefing("# brief\n", archivingPrevious: false, now: Self.stamp)
    try store.writeContext(outgoingAgent: .claudeCode, repo: .notGit, session: nil, now: Self.stamp)
    let path = try store.archiveCurrent(from: "claude-code", to: "codex", now: Self.stamp)
    #expect(path == ".codans/handoff/archive/20231114-221320-claude-code-to-codex.md")
    let snapshot = try Self.read(store.rootURL.appending(path: path!))
    #expect(snapshot.hasPrefix("# brief\n\n# Handoff Context"))
    // The current briefing stays until the caller replaces or removes it.
    #expect(store.hasCurrentBriefing)

    // A same-second second archive gets a numbered sibling, never an overwrite.
    let second = try store.archiveCurrent(from: "claude-code", to: "codex", now: Self.stamp)
    #expect(second == ".codans/handoff/archive/20231114-221320-claude-code-to-codex-2.md")
  }

  @Test
  func contextRendersRepoAndSessionFacts() throws {
    let store = HandoffStore(rootURL: try Self.makeRoot())
    let session = HandoffSessionContext(
      agentKind: .codex,
      sessionID: "01HXYZ",
      paneID: "p-1",
      paneTitle: "codex — fix",
      screenExcerpt: "  > done\n"
    )
    let record = try store.writeSession(session, now: Self.stamp)
    #expect(record.excerptPath == ".codans/handoff/sessions/20231114-221320-p-1.md")
    #expect(record.resumeCommand == "codex resume '01HXYZ'")
    let excerpt = try Self.read(store.rootURL.appending(path: record.excerptPath))
    #expect(excerpt.contains("```text\n> done\n```"))
    #expect(excerpt.contains("- Reattach: `codex resume '01HXYZ'`"))

    let repo = HandoffRepoState(
      branch: "feat/x", isGit: true, changedFiles: ["a.swift", "b/c.md"], additions: 3, deletions: 1)
    try store.writeContext(outgoingAgent: .codex, repo: repo, session: record, now: Self.stamp)
    let context = try Self.read(store.contextURL)
    #expect(context.contains("- Agent: Codex"))
    #expect(context.contains("- Branch: feat/x"))
    #expect(context.contains("- Changed files: 2"))
    #expect(context.contains("- Uncommitted diff: +3 / -1"))
    #expect(context.contains("- `b/c.md`"))
    #expect(context.contains("- Screen excerpt: `.codans/handoff/sessions/20231114-221320-p-1.md`"))
    #expect(context.contains("- Reattach to the outgoing session: `codex resume '01HXYZ'`"))
  }

  @Test
  func contextForAPlainDirectorySaysSo() throws {
    let store = HandoffStore(rootURL: try Self.makeRoot())
    try store.writeContext(outgoingAgent: nil, repo: .notGit, session: nil, now: Self.stamp)
    let context = try Self.read(store.contextURL)
    #expect(context.contains("- Agent: unknown"))
    #expect(context.contains("- Not a git repository"))
    #expect(!context.contains("## Session Context"))
  }

  @Test
  func logAppendsTimestampedLinesUnderAHeader() throws {
    let store = HandoffStore(rootURL: try Self.makeRoot())
    try store.appendLog("first", now: Self.stamp)
    try store.appendLog("second", now: Self.stamp)
    #expect(
      try Self.read(store.logURL)
        == "# Handoff log\n\n- 2023-11-14T22:13:20Z  first\n- 2023-11-14T22:13:20Z  second\n")
  }

  @Test
  func slugsAreFilenameSafe() {
    #expect(HandoffStore.slug("Claude Code") == "claude-code")
    #expect(HandoffStore.slug("  weird//name!! ") == "weird-name")
    #expect(HandoffStore.slug("") == "agent")
    #expect(HandoffStore.slug("F3A2-9C") == "f3a2-9c")
  }
}
