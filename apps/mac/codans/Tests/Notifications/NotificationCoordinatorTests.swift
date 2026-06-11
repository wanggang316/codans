import Foundation
import Testing
import CodansCore

@testable import Codans

/// Behavioural tests for `NotificationCoordinator` (M2.T2). Each test
/// declares the AC ID it covers; the runtime probe at the milestone gate
/// is the authoritative check, but these tests pin the production code
/// path so a future refactor cannot silently regress the chokepoint.
@MainActor
struct NotificationCoordinatorTests {
  // MARK: - Test fixtures

  private func makeInbox() -> (NotificationStore, URL) {
    let url = FileManager.default.temporaryDirectory.appending(
      component: "notif-coordinator-\(UUID().uuidString).json"
    )
    return (NotificationStore(fileURL: url), url)
  }

  private func makeCandidate(
    sourceIsFocused: Bool = false,
    source: InboxEntry.SourcePath? = nil,
    kind: InboxEntry.Kind = .taskFinished
  ) -> NotificationCoordinator.Candidate {
    let resolvedSource =
      source
      ?? InboxEntry.SourcePath(
        projectID: ProjectID(),
        worktreeID: WorktreeID(),
        tabID: TabID(),
        paneID: PaneID()
      )
    let entry = InboxEntry(
      kind: kind,
      title: "fixture",
      body: "fixture-body",
      source: resolvedSource
    )
    return .init(entry: entry, sourceIsFocused: sourceIsFocused)
  }

  private func makeCoordinator(
    inbox: NotificationStore,
    notifier: MockOSNotifier,
    reader: FakeNotificationSettingsReader,
    catalog: HierarchyClient? = nil
  ) -> NotificationCoordinator {
    NotificationCoordinator(
      inbox: inbox,
      osNotifier: notifier,
      settingsReader: reader,
      catalog: catalog ?? Self.silentCatalog(),
      now: { Date() }
    )
  }

  /// A `HierarchyClient` whose `promoteWorktree` is a no-op. Used as the
  /// default for tests that do not exercise the promote branch, so the
  /// shipped `HierarchyClient.testValue` (which raises a test issue when
  /// `promoteWorktree` is invoked via `unimplemented(...)`) does not
  /// trip on every 0→N unread edge — `moveNotifiedWorktreeToTop`
  /// defaults to true.
  @MainActor
  private static func silentCatalog() -> HierarchyClient {
    var client = HierarchyClient.testValue
    client.promoteWorktree = { _, _, _ in }
    return client
  }

  /// Records every `promoteWorktree` invocation so tests can assert on
  /// call count and arguments. M6.T2 promote behaviour matrix.
  @MainActor
  private final class PromoteRecorder {
    private(set) var calls: [(ProjectID, WorktreeID, WorktreePromotionMode)] = []
    func record(_ projectID: ProjectID, _ worktreeID: WorktreeID, _ mode: WorktreePromotionMode) {
      calls.append((projectID, worktreeID, mode))
    }
  }

  /// Wires `recorder.record` into `HierarchyClient.promoteWorktree`. All
  /// other methods stay at `testValue` (raise a test issue if invoked),
  /// so accidental calls into the unrelated catalog surface still fail
  /// loudly.
  @MainActor
  private static func recordingCatalog(_ recorder: PromoteRecorder) -> HierarchyClient {
    var client = HierarchyClient.testValue
    client.promoteWorktree = { projectID, worktreeID, mode in
      recorder.record(projectID, worktreeID, mode)
    }
    return client
  }

  // MARK: - Tests

  /// AC-V11-CP-001 (negative path): a candidate whose source matches the
  /// globally-focused pane is dropped before any sink fires — no inbox
  /// row, no banner, no badge update. The only `.dropped` reason the
  /// coordinator returns.
  @Test
  func focusedSourceDropsBeforeAnySink() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    let decision = await coordinator.handle(makeCandidate(sourceIsFocused: true))

    #expect(decision == .dropped(reason: .sourceIsFocused))
    #expect(inbox.entries.isEmpty)
    #expect(notifier.posts.isEmpty)
  }

  /// AC-V11-CP-001: the coordinator reads settings at decision time, so a
  /// settings flip between two candidates takes effect on the second.
  @Test
  func evaluatesLiveSettingsAtDecisionTime() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    _ = await coordinator.handle(makeCandidate())
    #expect(inbox.entries.count == 1)

    reader.notifications.inAppEnabled = false
    let decision2 = await coordinator.handle(makeCandidate())

    #expect(inbox.entries.count == 1)
    // Lock the "live read at decision time" semantics: the second decision
    // must report `inAppAppended == false` because the flag flipped between
    // calls. Asserting on inbox count alone leaves room for a future
    // regression where the count happens to stay flat for an unrelated
    // reason (e.g. dedup) while `inAppAppended` lies.
    guard case .posted(let inAppAppended, _, _, _, _) = decision2 else {
      Issue.record("expected .posted, got \(decision2)")
      return
    }
    #expect(inAppAppended == false)
  }

  /// AC-V11-CP-002: dropping a candidate must not retroactively surface
  /// when the toggle flips back on later. The dropped candidate is gone.
  @Test
  func droppedCandidateDoesNotResurfaceOnToggleFlip() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    _ = await coordinator.handle(makeCandidate())

    reader.notifications.inAppEnabled = false
    _ = await coordinator.handle(makeCandidate())
    #expect(inbox.entries.count == 1)

    reader.notifications.inAppEnabled = true
    // No new candidate fed — the previously dropped one stays dropped.
    #expect(inbox.entries.count == 1)
  }

  /// Regression guard for the I-1 / I-2 fix: when `InboxStorage.appending`
  /// merges a second candidate into the prior entry (same `(paneID, kind)`
  /// within the 30 s dedup window, preserving the prior `readAt`), the
  /// coordinator must report `inAppAppended == false` for the merged
  /// candidate and must not double-count the worktree in
  /// `unreadByWorktree`. Without this guard, M6.T2's promote logic would
  /// see a synthetic 0→N edge for chatty panes whose dedup was designed
  /// to suppress exactly that.
  @Test
  func dedupDoesNotDoubleCountUnreadInCache() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    // Both candidates share the same source path + kind so InboxStorage's
    // 30 s `(paneID, kind)` dedup window collapses the second into the
    // first.
    let source = InboxEntry.SourcePath(
      projectID: ProjectID(),
      worktreeID: WorktreeID(),
      tabID: TabID(),
      paneID: PaneID()
    )
    let first = await coordinator.handle(makeCandidate(source: source))
    let second = await coordinator.handle(makeCandidate(source: source))

    guard case .posted(let firstAppended, _, _, _, _) = first,
      case .posted(let secondAppended, _, _, _, _) = second
    else {
      Issue.record("expected .posted for both decisions")
      return
    }
    #expect(firstAppended == true)
    #expect(secondAppended == false)
    #expect(inbox.entries.count == 1)
    #expect(coordinator.unreadByWorktree[source.worktreeID] == 1)
  }

  /// AC-V11-S-001: with the inbox off and system banners on, only the
  /// OS banner fires.
  @Test
  func inAppOffPostsBannerSkipsInbox() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    notifier.status = .authorized
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = false
    reader.notifications.systemEnabled = true
    reader.authStatus = .authorized
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    let decision = await coordinator.handle(makeCandidate())

    #expect(notifier.posts.count == 1)
    #expect(inbox.entries.isEmpty)
    if case .posted(let inAppAppended, let osBannerPosted, _, let badgeUpdated, _) = decision {
      #expect(inAppAppended == false)
      #expect(osBannerPosted == true)
      #expect(badgeUpdated == false)
    } else {
      Issue.record("expected .posted, got \(decision)")
    }
  }

  /// AC-V11-S-002: with the inbox on and system banners off, only the
  /// inbox grows.
  @Test
  func systemOffAppendsInboxSkipsBanner() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    reader.notifications.systemEnabled = false
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    let decision = await coordinator.handle(makeCandidate())

    #expect(inbox.entries.count == 1)
    #expect(notifier.posts.isEmpty)
    if case .posted(let inAppAppended, let osBannerPosted, _, _, _) = decision {
      #expect(inAppAppended == true)
      #expect(osBannerPosted == false)
    } else {
      Issue.record("expected .posted, got \(decision)")
    }
  }

  /// AC-V11-S-003: with sound off, the banner still posts but the
  /// `playSound` argument forwarded to `OSNotifier.post` is false.
  @Test
  func soundOffPostsWithoutSound() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    notifier.status = .authorized
    let reader = FakeNotificationSettingsReader()
    reader.notifications.systemEnabled = true
    reader.notifications.soundEnabled = false
    reader.authStatus = .authorized
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    let decision = await coordinator.handle(makeCandidate())

    #expect(notifier.posts.count == 1)
    #expect(notifier.posts.last?.playSound == false)
    if case .posted(_, _, let soundPlayed, _, _) = decision {
      #expect(soundPlayed == false)
    } else {
      Issue.record("expected .posted, got \(decision)")
    }
  }

  /// AC-V11-S-005: with the dock badge toggle off, `Decision.badgeUpdated`
  /// is false even though the inbox still grows. (Production reads the
  /// badge from the inbox via `recomputeDockBadge` calling
  /// `DockBadger.setBadge(badgeCount)`. We assert against the highest-
  /// fidelity observable on the public `Decision` surface to avoid
  /// injecting a fake badger.)
  @Test
  func dockBadgeOffReportsNoBadgeUpdate() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    reader.notifications.dockBadgeEnabled = false
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    let decisionOff = await coordinator.handle(makeCandidate())

    if case .posted(_, _, _, let badgeUpdated, _) = decisionOff {
      #expect(badgeUpdated == false)
    } else {
      Issue.record("expected .posted, got \(decisionOff)")
    }

    // Sanity check the other branch: with the badge toggle on,
    // `badgeUpdated` flips to true.
    reader.notifications.dockBadgeEnabled = true
    let decisionOn = await coordinator.handle(makeCandidate())
    if case .posted(_, _, _, let badgeUpdated, _) = decisionOn {
      #expect(badgeUpdated == true)
    } else {
      Issue.record("expected .posted, got \(decisionOn)")
    }
  }

  /// AC-V11-L-001 (static expectation): coordinator emits a drop log line
  /// at `.debug` whenever a gate suppressed a surface. Tested via the
  /// internal `lastDropReasons` seam — the runtime probe at the milestone
  /// gate is the authoritative L-001 check; this test just guarantees the
  /// production code path that emits the log lines is exercised.
  @Test
  func logsDropReasonsOnSuppressedGates() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = false
    reader.notifications.systemEnabled = false
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    _ = await coordinator.handle(makeCandidate())

    #expect(coordinator.lastDropReasons.contains(.inAppDisabled))
    #expect(coordinator.lastDropReasons.contains(.systemDisabled))
  }

  // MARK: - M6.T2: worktree promote on 0→N unread edge

  /// AC-V11-WT-001 / UT-V11-WT-001: the first unread for a worktree
  /// invokes `catalog.promoteWorktree(projectID, worktreeID,
  /// .moveToFrontWithinUnpinned)` and the decision reports
  /// `promoted: true`. The coordinator does not inspect pinned-ness —
  /// the catalog enforces that (M6.T1).
  @Test
  func firstUnreadForUnpinnedWorktreePromotes() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    reader.notifications.moveNotifiedWorktreeToTop = true
    let recorder = PromoteRecorder()
    let coordinator = makeCoordinator(
      inbox: inbox,
      notifier: notifier,
      reader: reader,
      catalog: Self.recordingCatalog(recorder)
    )

    let source = InboxEntry.SourcePath(
      projectID: ProjectID(),
      worktreeID: WorktreeID(),
      tabID: TabID(),
      paneID: PaneID()
    )
    let decision = await coordinator.handle(makeCandidate(source: source))

    guard case .posted(_, _, _, _, let promoted) = decision else {
      Issue.record("expected .posted, got \(decision)")
      return
    }
    #expect(promoted == true)
    #expect(recorder.calls.count == 1)
    #expect(recorder.calls.first?.0 == source.projectID)
    #expect(recorder.calls.first?.1 == source.worktreeID)
    #expect(recorder.calls.first?.2 == .moveToFrontWithinUnpinned)
  }

  /// AC-V11-WT-002 / UT-V11-WT-002: a second unread on the SAME worktree
  /// (different paneID so dedup does not collapse it) must not re-promote
  /// — `before > 0`, so the gate short-circuits.
  @Test
  func secondUnreadOnSameWorktreeDoesNotRetrigger() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    reader.notifications.moveNotifiedWorktreeToTop = true
    let recorder = PromoteRecorder()
    let coordinator = makeCoordinator(
      inbox: inbox,
      notifier: notifier,
      reader: reader,
      catalog: Self.recordingCatalog(recorder)
    )

    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()
    let firstSource = InboxEntry.SourcePath(
      projectID: projectID, worktreeID: worktreeID, tabID: tabID, paneID: PaneID()
    )
    let secondSource = InboxEntry.SourcePath(
      projectID: projectID, worktreeID: worktreeID, tabID: tabID, paneID: PaneID()
    )

    _ = await coordinator.handle(makeCandidate(source: firstSource))
    let second = await coordinator.handle(makeCandidate(source: secondSource))

    guard case .posted(_, _, _, _, let promoted) = second else {
      Issue.record("expected .posted, got \(second)")
      return
    }
    #expect(promoted == false)
    #expect(recorder.calls.count == 1)
  }

  /// AC-V11-WT-003 / UT-V11-WT-003: marking read does NOT demote. The
  /// coordinator never calls back into `promoteWorktree` on read
  /// transitions (there is no such code path); we assert by verifying
  /// the recorder remains at one call after `markAllRead`.
  ///
  /// Then: a fresh 0→N unread edge on the same worktree DOES re-promote
  /// (because `before == 0` again post-mark-read). This matches the spec
  /// reading of WT-003 (position not restored when unread drops to 0)
  /// composed with WT-001 (every 0→N edge promotes).
  @Test
  func markReadAllowsRePromoteOnNextZeroToOneEdge() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    reader.notifications.moveNotifiedWorktreeToTop = true
    let recorder = PromoteRecorder()
    let coordinator = makeCoordinator(
      inbox: inbox,
      notifier: notifier,
      reader: reader,
      catalog: Self.recordingCatalog(recorder)
    )

    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()
    let firstSource = InboxEntry.SourcePath(
      projectID: projectID, worktreeID: worktreeID, tabID: tabID, paneID: PaneID()
    )
    _ = await coordinator.handle(makeCandidate(source: firstSource))
    #expect(recorder.calls.count == 1)

    inbox.markAllRead()
    // No catalog call should have been issued by the mark-read transition.
    #expect(recorder.calls.count == 1)

    // Fresh 0→N edge on the same worktree (new pane to bypass dedup).
    let secondSource = InboxEntry.SourcePath(
      projectID: projectID, worktreeID: worktreeID, tabID: tabID, paneID: PaneID()
    )
    let decision = await coordinator.handle(makeCandidate(source: secondSource))
    guard case .posted(_, _, _, _, let promoted) = decision else {
      Issue.record("expected .posted, got \(decision)")
      return
    }
    #expect(promoted == true)
    #expect(recorder.calls.count == 2)
  }

  /// AC-V11-WT-004 / UT-V11-WT-004: with the toggle off, no promote
  /// fires even on a fresh 0→N unread edge. Inbox still appends.
  @Test
  func disableToggleSuppressesPromote() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    reader.notifications.moveNotifiedWorktreeToTop = false
    let recorder = PromoteRecorder()
    let coordinator = makeCoordinator(
      inbox: inbox,
      notifier: notifier,
      reader: reader,
      catalog: Self.recordingCatalog(recorder)
    )

    let decision = await coordinator.handle(makeCandidate())

    guard case .posted(let inAppAppended, _, _, _, let promoted) = decision else {
      Issue.record("expected .posted, got \(decision)")
      return
    }
    #expect(inAppAppended == true)
    #expect(promoted == false)
    #expect(recorder.calls.isEmpty)
  }

  /// AC-V11-WT-006 / UT-V11-WT-006 (coordinator-side half): the
  /// coordinator does not inspect pinned-ness. It issues
  /// `promoteWorktree` for every 0→N edge that passes the toggle gate;
  /// the catalog (`HierarchyManager.promoteWorktree`, M6.T1) silently
  /// no-ops on pinned targets. This test pins the policy split.
  @Test
  func promoteCallFiresRegardlessOfPinnedStatus() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    reader.notifications.moveNotifiedWorktreeToTop = true
    let recorder = PromoteRecorder()
    let coordinator = makeCoordinator(
      inbox: inbox,
      notifier: notifier,
      reader: reader,
      catalog: Self.recordingCatalog(recorder)
    )

    // The coordinator has no isPinned signal in scope — the catalog
    // enforces the exclusion. Exercising the path simply confirms the
    // call always reaches the catalog.
    _ = await coordinator.handle(makeCandidate())
    #expect(recorder.calls.count == 1)
  }

  // MARK: - M8.T1: inbox-reset quarantine toast

  /// Synthesize an arbitrary backup URL with a controlled basename so the
  /// test can assert idempotency-marker content without depending on
  /// `InboxFile.quarantinePath()`.
  private func makeBackupURL(basename: String = "notifications.json.bak-20260520T120000Z") -> URL {
    FileManager.default.temporaryDirectory.appending(component: basename)
  }

  /// Build a sandboxed marker URL inside the temp dir so tests never touch
  /// the user's real `~/.config/codans/notifications.quarantine-shown`.
  private func makeMarkerURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(component: "notif-quarantine-\(UUID().uuidString).marker")
  }

  /// UT-V11-J-003 (first launch leg): with no pre-existing marker, the
  /// coordinator appends a single "Inbox reset" entry and writes the
  /// marker file with the backup basename as its contents.
  @Test
  func emitQuarantineNotice_writesMarkerAndEmitsOnFirstCall() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    let backupURL = makeBackupURL(basename: "notifications.json.bak-20260520T120000Z")
    let markerURL = makeMarkerURL()
    defer { try? FileManager.default.removeItem(at: markerURL) }

    await coordinator.emitQuarantineNotice(backupURL: backupURL, markerURL: markerURL)

    #expect(inbox.entries.count == 1)
    #expect(inbox.entries.first?.title == "Inbox reset")
    let markerContent = try String(contentsOf: markerURL, encoding: .utf8)
    #expect(markerContent == "notifications.json.bak-20260520T120000Z")
  }

  /// UT-V11-J-003 (relaunch leg): with the marker already recording the
  /// current quarantine's backup basename, the coordinator is a no-op —
  /// the toast was shown on a prior launch and must not re-surface.
  @Test
  func emitQuarantineNotice_isIdempotentWhenMarkerMatches() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    let basename = "notifications.json.bak-20260520T120000Z"
    let backupURL = makeBackupURL(basename: basename)
    let markerURL = makeMarkerURL()
    defer { try? FileManager.default.removeItem(at: markerURL) }
    try Data(basename.utf8).write(to: markerURL, options: .atomic)

    await coordinator.emitQuarantineNotice(backupURL: backupURL, markerURL: markerURL)

    #expect(inbox.entries.isEmpty)
  }

  /// A SECOND quarantine event (different backup basename, e.g. user
  /// downgraded twice) must re-fire the toast and rewrite the marker so
  /// the next launch's check matches the new basename.
  @Test
  func emitQuarantineNotice_reFiresOnDifferentBackupBasename() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    let markerURL = makeMarkerURL()
    defer { try? FileManager.default.removeItem(at: markerURL) }
    try Data("notifications.json.bak-A".utf8).write(to: markerURL, options: .atomic)

    let newBackupURL = makeBackupURL(basename: "notifications.json.bak-B")
    await coordinator.emitQuarantineNotice(backupURL: newBackupURL, markerURL: markerURL)

    #expect(inbox.entries.count == 1)
    #expect(inbox.entries.first?.title == "Inbox reset")
    let markerContent = try String(contentsOf: markerURL, encoding: .utf8)
    #expect(markerContent == "notifications.json.bak-B")
  }

  /// The synthetic candidate flows through `handle(_:)` like any other —
  /// the chokepoint gates (`inAppEnabled` etc.) suppress the inbox row
  /// when off. The marker is STILL written so a relaunch does not keep
  /// retrying: the user's "no banners right now" intent should not turn
  /// the quarantine notice into a persistent boot-time pop-up.
  @Test
  func emitQuarantineNotice_routedThroughChokepointGates() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = false
    reader.notifications.systemEnabled = false
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    let backupURL = makeBackupURL(basename: "notifications.json.bak-gated")
    let markerURL = makeMarkerURL()
    defer { try? FileManager.default.removeItem(at: markerURL) }

    await coordinator.emitQuarantineNotice(backupURL: backupURL, markerURL: markerURL)

    #expect(inbox.entries.isEmpty)
    // Marker written regardless of gate outcome — see doc comment on
    // `emitQuarantineNotice` for the design rationale.
    let markerContent = try String(contentsOf: markerURL, encoding: .utf8)
    #expect(markerContent == "notifications.json.bak-gated")
  }

  /// AC-V11-WT-005 / UT-V11-WT-005: a deduped candidate (same
  /// `(paneID, kind)` within 30 s) does NOT trigger promote because
  /// `didAppend == false`. Confirms the M2.T2 round-2 dedup→delta
  /// composition holds end-to-end through the promote branch.
  @Test
  func dedupedDuplicateDoesNotPromote() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    reader.notifications.moveNotifiedWorktreeToTop = true
    let recorder = PromoteRecorder()
    let coordinator = makeCoordinator(
      inbox: inbox,
      notifier: notifier,
      reader: reader,
      catalog: Self.recordingCatalog(recorder)
    )

    let source = InboxEntry.SourcePath(
      projectID: ProjectID(),
      worktreeID: WorktreeID(),
      tabID: TabID(),
      paneID: PaneID()
    )
    _ = await coordinator.handle(makeCandidate(source: source))
    let second = await coordinator.handle(makeCandidate(source: source))

    guard case .posted(let secondAppended, _, _, _, let promoted) = second else {
      Issue.record("expected .posted, got \(second)")
      return
    }
    #expect(secondAppended == false)
    #expect(promoted == false)
    #expect(recorder.calls.count == 1)
  }
}
