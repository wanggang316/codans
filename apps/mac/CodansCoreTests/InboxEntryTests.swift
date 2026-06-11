import Foundation
import Testing

@testable import CodansCore

struct InboxEntryTests {
  // MARK: - Fixtures

  private func makeSource() -> InboxEntry.SourcePath {
    InboxEntry.SourcePath(
      projectID: ProjectID(),
      worktreeID: WorktreeID(),
      tabID: TabID(),
      paneID: PaneID()
    )
  }

  // MARK: - Identity & isUnread

  @Test
  func freshlyCreatedEntryIsUnread() {
    let entry = InboxEntry(kind: .taskFinished, title: "t", body: "b", source: makeSource())
    #expect(entry.isUnread)
    #expect(entry.readAt == nil)
  }

  @Test
  func entryWithReadAtIsRead() {
    var entry = InboxEntry(kind: .taskFinished, title: "t", body: "b", source: makeSource())
    entry.readAt = Date()
    #expect(!entry.isUnread)
  }

  @Test
  func defaultIDsAreUnique() {
    let a = InboxEntry(kind: .waitingForInput, title: "t", body: "b", source: makeSource())
    let b = InboxEntry(kind: .waitingForInput, title: "t", body: "b", source: makeSource())
    #expect(a.id != b.id)
  }

  // MARK: - Codable

  @Test
  func roundTripPreservesAllFields() throws {
    let source = makeSource()
    let original = InboxEntry(
      id: NotificationID(),
      kind: .waitingForInput,
      title: "Permission required",
      body: "Allow read of /etc/passwd?",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      readAt: Date(timeIntervalSince1970: 1_700_000_010),
      source: source
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(InboxEntry.self, from: data)

    #expect(decoded == original)
  }

  @Test
  func kindEnumCasesUseLiteralRawValues() throws {
    let waiting = try JSONEncoder().encode(InboxEntry.Kind.waitingForInput)
    #expect(String(data: waiting, encoding: .utf8) == "\"waitingForInput\"")
    let done = try JSONEncoder().encode(InboxEntry.Kind.taskFinished)
    #expect(String(data: done, encoding: .utf8) == "\"taskFinished\"")
  }

  @Test
  func unreadEntryOmitsReadAtKeyOnEncode() throws {
    let entry = InboxEntry(kind: .taskFinished, title: "t", body: "b", source: makeSource())
    let data = try JSONEncoder().encode(entry)
    let json = String(data: data, encoding: .utf8) ?? ""
    // readAt is nil; default encoder strategy emits no "readAt" key for nil
    // optionals. This protects against an accidental change to the property
    // wrapper or coding strategy that would write `"readAt": null` and bloat
    // every persisted row.
    #expect(!json.contains("readAt"))
  }
}
