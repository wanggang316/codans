import Foundation
import Testing

@testable import CodansCore

struct InboxStorageTests {
  // MARK: - Fixtures

  private func entry(
    paneID: PaneID = PaneID(),
    kind: InboxEntry.Kind = .taskFinished,
    title: String = "t",
    body: String = "b",
    createdAt: Date = Date(),
    readAt: Date? = nil
  ) -> InboxEntry {
    InboxEntry(
      kind: kind,
      title: title,
      body: body,
      createdAt: createdAt,
      readAt: readAt,
      source: InboxEntry.SourcePath(
        projectID: ProjectID(),
        worktreeID: WorktreeID(),
        tabID: TabID(),
        paneID: paneID
      )
    )
  }

  // MARK: - Append / dedup

  @Test
  func appendingEmptyInboxYieldsSingleton() {
    let result = InboxStorage.appending(entry(), to: [])
    #expect(result.count == 1)
  }

  @Test
  func appendingPrependsNewestFirst() {
    let now = Date()
    let older = entry(createdAt: now.addingTimeInterval(-100))
    let newer = entry(createdAt: now)
    let result = InboxStorage.appending(newer, to: [older])
    #expect(result.map(\.id) == [newer.id, older.id])
  }

  @Test
  func dedupWithinWindowMergesOnSamePaneAndKind() {
    let pane = PaneID()
    let now = Date()
    let prior = entry(paneID: pane, kind: .taskFinished, title: "old", createdAt: now.addingTimeInterval(-10))
    let updated = entry(paneID: pane, kind: .taskFinished, title: "new", createdAt: now)

    let result = InboxStorage.appending(updated, to: [prior])

    #expect(result.count == 1)
    #expect(result[0].id == prior.id)             // id of the prior row preserved
    #expect(result[0].title == "new")             // body refreshed
    #expect(result[0].createdAt == now)
  }

  @Test
  func dedupOutsideWindowAppends() {
    let pane = PaneID()
    let now = Date()
    let prior = entry(paneID: pane, kind: .taskFinished, createdAt: now.addingTimeInterval(-60))
    let later = entry(paneID: pane, kind: .taskFinished, createdAt: now)
    let result = InboxStorage.appending(later, to: [prior])
    #expect(result.count == 2)
  }

  @Test
  func dedupRespectsKindBoundary() {
    let pane = PaneID()
    let now = Date()
    let waiting = entry(paneID: pane, kind: .waitingForInput, createdAt: now.addingTimeInterval(-5))
    let finished = entry(paneID: pane, kind: .taskFinished, createdAt: now)
    let result = InboxStorage.appending(finished, to: [waiting])
    #expect(result.count == 2)
  }

  @Test
  func dedupRespectsPaneBoundary() {
    let now = Date()
    let onA = entry(paneID: PaneID(), kind: .taskFinished, createdAt: now.addingTimeInterval(-5))
    let onB = entry(paneID: PaneID(), kind: .taskFinished, createdAt: now)
    let result = InboxStorage.appending(onB, to: [onA])
    #expect(result.count == 2)
  }

  @Test
  func dedupPreservesReadAtFromPriorEntry() {
    let pane = PaneID()
    let now = Date()
    let priorReadAt = now.addingTimeInterval(-2)
    let prior = entry(paneID: pane, createdAt: now.addingTimeInterval(-10), readAt: priorReadAt)
    let updated = entry(paneID: pane, createdAt: now)
    let result = InboxStorage.appending(updated, to: [prior])
    #expect(result.count == 1)
    #expect(result[0].readAt == priorReadAt)
  }

  // MARK: - Age sweep

  @Test
  func ageSweepDropsEntriesOlderThanSevenDays() {
    let now = Date()
    let fresh = entry(createdAt: now.addingTimeInterval(-60))
    let stale = entry(createdAt: now.addingTimeInterval(-(InboxStorage.maxAge + 60)))
    let result = InboxStorage.aged([fresh, stale], asOf: now)
    #expect(result.map(\.id) == [fresh.id])
  }

  @Test
  func ageSweepKeepsBoundaryEntries() {
    let now = Date()
    let exactlyAtBoundary = entry(createdAt: now.addingTimeInterval(-InboxStorage.maxAge))
    let result = InboxStorage.aged([exactlyAtBoundary], asOf: now)
    #expect(result.count == 1)
  }

  // MARK: - Cap sweep

  @Test
  func capSweepIsNoopWhenUnderCap() {
    let entries = (0..<10).map { _ in entry() }
    let result = InboxStorage.capped(entries)
    #expect(result.count == 10)
  }

  @Test
  func capSweepEvictsOldestReadFirst() {
    // Build cap+1 entries, newest first, alternating read/unread.
    let now = Date()
    let entries: [InboxEntry] = (0..<(InboxStorage.cap + 1)).map { i in
      let createdAt = now.addingTimeInterval(-Double(i))
      let readAt: Date? = (i % 2 == 0) ? createdAt.addingTimeInterval(1) : nil
      return entry(createdAt: createdAt, readAt: readAt)
    }
    let result = InboxStorage.capped(entries)
    #expect(result.count == InboxStorage.cap)
    // The evicted entry must be the oldest read one, i.e. the read entry
    // closest to the tail of the newest-first array.
    let evictedID = entries.last(where: { !$0.isUnread })?.id
    #expect(evictedID != nil)
    #expect(!result.contains { $0.id == evictedID })
  }

  @Test
  func capSweepEvictsOldestUnreadWhenAllUnread() {
    let now = Date()
    let entries: [InboxEntry] = (0..<(InboxStorage.cap + 1)).map { i in
      entry(createdAt: now.addingTimeInterval(-Double(i)))
    }
    let result = InboxStorage.capped(entries)
    #expect(result.count == InboxStorage.cap)
    // The evicted is the tail (oldest unread).
    let evictedID = entries.last?.id
    #expect(!result.contains { $0.id == evictedID })
  }

  // MARK: - Read-state mutators

  @Test
  func markingReadFlipsTargetEntry() {
    let pane = PaneID()
    let target = entry(paneID: pane)
    let other = entry(paneID: PaneID())
    let now = Date()
    let result = InboxStorage.markingRead(id: target.id, in: [target, other], at: now)
    #expect(result.first(where: { $0.id == target.id })?.readAt == now)
    #expect(result.first(where: { $0.id == other.id })?.readAt == nil)
  }

  @Test
  func markingReadIsIdempotentOnAlreadyReadEntry() {
    let originalReadAt = Date(timeIntervalSince1970: 1_700_000_000)
    let alreadyRead = entry(readAt: originalReadAt)
    let result = InboxStorage.markingRead(id: alreadyRead.id, in: [alreadyRead], at: Date())
    #expect(result[0].readAt == originalReadAt)   // not overwritten
  }

  @Test
  func markingAllReadFlipsEveryUnreadAtSameTimestamp() {
    let now = Date()
    let priorRead = entry(readAt: now.addingTimeInterval(-100))
    let unreadA = entry()
    let unreadB = entry()
    let result = InboxStorage.markingAllRead(in: [priorRead, unreadA, unreadB], at: now)
    #expect(result.first(where: { $0.id == priorRead.id })?.readAt == now.addingTimeInterval(-100))
    #expect(result.first(where: { $0.id == unreadA.id })?.readAt == now)
    #expect(result.first(where: { $0.id == unreadB.id })?.readAt == now)
  }

  @Test
  func unreadCountIgnoresReadEntries() {
    let entries = [
      entry(readAt: Date()),
      entry(),
      entry(),
    ]
    #expect(InboxStorage.unreadCount(entries) == 2)
  }

  // MARK: - Orphan sweep

  @Test
  func markingReadForOrphanPanesFlipsOnlyOrphanUnreads() {
    let now = Date()
    let liveA = PaneID()
    let liveB = PaneID()
    let orphan = PaneID()

    let liveUnread = entry(paneID: liveA)
    let orphanUnread = entry(paneID: orphan)
    let orphanAlreadyRead = entry(paneID: orphan, readAt: now.addingTimeInterval(-100))

    let result = InboxStorage.markingReadForOrphanPanes(
      livePaneIDs: [liveA, liveB],
      in: [liveUnread, orphanUnread, orphanAlreadyRead],
      at: now
    )

    #expect(result.first(where: { $0.id == liveUnread.id })?.readAt == nil)
    #expect(result.first(where: { $0.id == orphanUnread.id })?.readAt == now)
    #expect(
      result.first(where: { $0.id == orphanAlreadyRead.id })?.readAt
        == now.addingTimeInterval(-100)
    )
  }

  @Test
  func markingReadForOrphanPanesWithEmptyLiveSetMarksEveryUnread() {
    let now = Date()
    let a = entry()
    let b = entry()
    let result = InboxStorage.markingReadForOrphanPanes(livePaneIDs: [], in: [a, b], at: now)
    #expect(result.allSatisfy { $0.readAt == now })
  }

  @Test
  func markingReadForOrphanPanesIsNoOpWhenAllPanesAreLive() {
    let pane = PaneID()
    let unread = entry(paneID: pane)
    let result = InboxStorage.markingReadForOrphanPanes(livePaneIDs: [pane], in: [unread])
    #expect(result == [unread])
  }
}
