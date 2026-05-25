import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Cross-subsystem invariant pin: when the same canned `TerminalEvent`
/// sequence is fed to both `NotificationDetector` (the notifications
/// subsystem's consumer) and `AgentRegistry` (the ActiveAgents
/// subsystem's consumer), the two consumers must remain in lockstep
/// about how the shared `DetectionTranslator.classify(title:body:)`
/// reading of a desktop notification (or the synthetic
/// `bellRang` / `paneIdle` cues) flows through their respective
/// output surfaces.
///
/// The two consumers take *different* downstream actions on the same
/// classifier verdict — registry flips runtime state, detector appends
/// an `InboxEntry` — but they must never disagree about the verdict
/// itself. A future change to one subsystem's classification path that
/// silently drifts away from the other will fail these tests visibly.
///
/// Scope (M2.T8): five focused scenarios A-E. Each test builds a
/// minimal catalog containing one `P1` and exercises both consumers
/// against the same event prefix.
@MainActor
struct AgentNotificationConsistencyTests {
  // MARK: - Test A: OSC 9 classified as waitingForInput

  /// Sequence: bind agent, paneOutput, OSC 9 (`"Approve this action?"`).
  /// Registry must end at `.waitingForInput`; detector must record one
  /// inbox entry with `kind == .waitingForInput`. Both arrive via
  /// `DetectionTranslator.classify`, which is also called directly to
  /// pin the shared verdict.
  @Test
  func oscNineWaitingForInputIsConsistent() async {
    let fixture = Fixture()
    let title = "Approve this action?"
    let body = "Yes / No"

    // Shared classifier verdict — the invariant under test.
    #expect(DetectionTranslator.classify(title: title, body: body) == .waitingForInput)

    let events: [TerminalEvent] = [
      // onAgentBound is not a TerminalEvent — drive the registry input directly.
      .paneOutput(fixture.paneID, Data()),
      .paneInfoChanged(fixture.paneID, .desktopNotification(title: title, body: body)),
    ]

    fixture.registry.onAgentBound(fixture.paneID, kind: .claudeCode, sessionID: nil)
    for event in events {
      fixture.registry.onTerminalEvent(event)
      await fixture.detector.handle(event)
    }

    // Registry side.
    #expect(fixture.registry.entries[fixture.paneID]?.state == .waitingForInput)

    // Detector side: one inbox entry, classified waitingForInput, sourced at P1.
    #expect(fixture.store.entries.count == 1)
    #expect(fixture.store.entries.first?.kind == .waitingForInput)
    #expect(fixture.store.entries.first?.source.paneID == fixture.paneID)
  }

  // MARK: - Test B: Bell ring (synthetic waitingForInput cue)

  /// Sequence: bind agent, paneOutput, `.bellRang`. Both consumers treat
  /// the bell as a waitingForInput cue. The detector's actual title
  /// string is `"Pane bell"` (per `DetectionTranslator.translate`'s bell
  /// branch); what matters is the `kind`, not the exact title.
  @Test
  func bellRangIsConsistent() async {
    let fixture = Fixture()
    let events: [TerminalEvent] = [
      .paneOutput(fixture.paneID, Data()),
      .paneInfoChanged(fixture.paneID, .bellRang),
    ]

    fixture.registry.onAgentBound(fixture.paneID, kind: .claudeCode, sessionID: nil)
    for event in events {
      fixture.registry.onTerminalEvent(event)
      await fixture.detector.handle(event)
    }

    #expect(fixture.registry.entries[fixture.paneID]?.state == .waitingForInput)

    #expect(fixture.store.entries.count == 1)
    #expect(fixture.store.entries.first?.kind == .waitingForInput)
    #expect(fixture.store.entries.first?.source.paneID == fixture.paneID)
  }

  // MARK: - Test C: OSC 9 classified as taskFinished — divergent
  //                 actions, same classifier

  /// Sequence: bind agent, paneOutput, OSC 9 (`"Build complete"` /
  /// `"Exited 0"`). Classifier verdict is `.taskFinished`. By design
  /// the registry treats `.taskFinished` as a no-op (the registry's
  /// task-finished path flows through `paneIdle` / `runningPanes` exit,
  /// not through the OSC 9 classifier); the detector still records the
  /// inbox row. The consistency invariant is the *shared verdict*; the
  /// divergent downstream actions are intentional.
  @Test
  func oscNineTaskFinishedIsConsistent() async {
    let fixture = Fixture()
    let title = "Build complete"
    let body = "Exited 0"

    #expect(DetectionTranslator.classify(title: title, body: body) == .taskFinished)

    let events: [TerminalEvent] = [
      .paneOutput(fixture.paneID, Data()),
      .paneInfoChanged(fixture.paneID, .desktopNotification(title: title, body: body)),
    ]

    fixture.registry.onAgentBound(fixture.paneID, kind: .claudeCode, sessionID: nil)
    for event in events {
      fixture.registry.onTerminalEvent(event)
      await fixture.detector.handle(event)
    }

    // Registry: no waitingForInput flip, no running set, no pending — stays idle.
    #expect(fixture.registry.entries[fixture.paneID]?.state == .idle)

    // Detector: inbox grew by one taskFinished entry.
    #expect(fixture.store.entries.count == 1)
    #expect(fixture.store.entries.first?.kind == .taskFinished)
    #expect(fixture.store.entries.first?.source.paneID == fixture.paneID)
  }

  // MARK: - Test D: OSC 9;4 busy lifecycle (loading → finished)

  /// Sequence: bind, input, runningPanes enters {P1}, paneOutput,
  /// runningPanes leaves ∅, paneIdle. Registry transitions loading →
  /// finished → finished. Detector fires a `.taskFinished` inbox entry
  /// from the paneIdle branch (gated on prior paneOutput having flipped
  /// the pane into
  /// `hasProducedOutput` and the duration crossing
  /// `DetectionTranslator.idleThreshold`).
  @Test
  func runningSetLifecycleIsConsistent() async {
    let fixture = Fixture()
    fixture.registry.onAgentBound(fixture.paneID, kind: .claudeCode, sessionID: nil)
    fixture.registry.onPaneKeyboardActivity(fixture.paneID)

    // Step 1: running set enters {P1}. AgentRegistry-only signal — the
    // detector consumes TerminalEvents, not running-set deltas, so there
    // is no detector input here.
    fixture.running.setValue([fixture.paneID])
    fixture.registry.onRunningPanesChanged([fixture.paneID])
    #expect(fixture.registry.entries[fixture.paneID]?.state == .loading)

    // Step 2: paneOutput. Both consumers see it; the detector records
    // the pane in its `hasProducedOutput` set so a subsequent paneIdle
    // can fire a taskFinished entry.
    let output = TerminalEvent.paneOutput(fixture.paneID, Data())
    fixture.registry.onTerminalEvent(output)
    await fixture.detector.handle(output)

    // Step 3: running set leaves ∅. AgentRegistry-only signal again.
    fixture.running.setValue([])
    fixture.registry.onRunningPanesChanged([])
    #expect(fixture.registry.entries[fixture.paneID]?.state == .finished)

    // Step 4: paneIdle with duration above the detector's threshold.
    // Registry: raw state is already idle after the runningPanes exit,
    // so the surfaced state stays at .finished.
    // Detector: pane has produced output AND duration ≥ idleThreshold,
    // so translator returns a .taskFinished entry.
    let idle = TerminalEvent.paneIdle(fixture.paneID, duration: DetectionTranslator.idleThreshold)
    fixture.registry.onTerminalEvent(idle)
    await fixture.detector.handle(idle)

    #expect(fixture.registry.entries[fixture.paneID]?.state == .finished)
    #expect(fixture.store.entries.count == 1)
    #expect(fixture.store.entries.first?.kind == .taskFinished)
    #expect(fixture.store.entries.first?.source.paneID == fixture.paneID)
  }

  // MARK: - Test E: paneExited teardown — divergent actions, shared
  //                 trigger event

  /// Sequence: bind, runningPanes enters {P1}, paneExited. Registry
  /// drops the entry entirely (teardown). Detector treats paneExited
  /// as bookkeeping-only — per `DetectionTranslator.translate`'s
  /// paneExited branch, the translator returns `entry: nil` (clean and
  /// user-initiated exits are intentionally silent; only `paneCrashed`
  /// and post-busy `paneIdle` cover the "needs attention" cases). The
  /// invariant is "both consumers process the same teardown event and
  /// reach mutually-consistent end states": registry forgets, detector
  /// records nothing in the inbox.
  @Test
  func paneExitedTeardownIsConsistent() async {
    let fixture = Fixture()
    fixture.registry.onAgentBound(fixture.paneID, kind: .claudeCode, sessionID: nil)

    fixture.running.setValue([fixture.paneID])
    fixture.registry.onRunningPanesChanged([fixture.paneID])
    #expect(fixture.registry.entries[fixture.paneID] != nil)

    let exit = TerminalEvent.paneExited(fixture.paneID, code: 0, signal: nil)
    fixture.registry.onTerminalEvent(exit)
    await fixture.detector.handle(exit)

    // Registry forgets the pane.
    #expect(fixture.registry.entries[fixture.paneID] == nil)
    // Detector emits no inbox entry for a clean paneExited.
    #expect(fixture.store.entries.isEmpty)
  }

  // MARK: - Fixture

  /// Per-test harness that stands up:
  ///  - an `AgentRegistry` with `LockIsolated`-backed running / focus
  ///    closures (mirrors `AgentRegistryStateTests.Fixture`).
  ///  - a real `NotificationStore` on a temp file URL.
  ///  - a real `NotificationCoordinator` wired to a `MockOSNotifier`
  ///    and a `FakeNotificationSettingsReader` (mirrors
  ///    `NotificationCoordinatorTests`).
  ///  - a real `NotificationDetector` whose `catalogSnapshot` returns a
  ///    one-project / one-worktree / one-tab / one-pane catalog with
  ///    `paneID == P1` so the detector can resolve `P1` to a
  ///    `SourcePath`.
  @MainActor
  final class Fixture {
    let paneID = PaneID()
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()

    let running = LockIsolated<Set<PaneID>>([])
    let focused = LockIsolated<PaneID?>(nil)

    let registry: AgentRegistry
    let store: NotificationStore
    let coordinator: NotificationCoordinator
    let detector: NotificationDetector

    init() {
      // Registry: closures read against test-controlled state.
      let running = self.running
      let focused = self.focused
      self.registry = AgentRegistry(
        runningPanes: { running.value },
        focusedPane: { focused.value }
      )

      // NotificationStore: ephemeral on-disk file in the temp dir; the
      // coordinator's `inAppEnabled` path appends to it. We do not
      // clean the temp file up — these tests run in the OS temp dir
      // and the basename is randomised so collisions are impossible.
      let storeURL = FileManager.default.temporaryDirectory.appending(
        component: "notif-consistency-\(UUID().uuidString).json"
      )
      self.store = NotificationStore(fileURL: storeURL)

      // Coordinator: fake reader leaves the v1.1 toggles at their
      // defaults (inAppEnabled = true, systemEnabled = true). Silent
      // catalog so promoteWorktree is a no-op (the M6.T2 promote branch
      // is not the invariant under test here).
      let notifier = MockOSNotifier()
      let reader = FakeNotificationSettingsReader()
      var hierarchyClient = HierarchyClient.testValue
      hierarchyClient.promoteWorktree = { _, _, _ in }
      self.coordinator = NotificationCoordinator(
        inbox: store,
        osNotifier: notifier,
        settingsReader: reader,
        catalog: hierarchyClient,
        now: { Date() }
      )

      // Detector: catalog snapshot resolves `paneID` to a real
      // (projectID, worktreeID, tabID, paneID) path. No mute label,
      // no app-frontmost gating — return false so the
      // globally-focused-pane check is a no-op and nothing gets dropped
      // by `sourceIsFocused`.
      let catalog = Self.makeCatalog(
        projectID: projectID,
        worktreeID: worktreeID,
        tabID: tabID,
        paneID: paneID
      )
      self.detector = NotificationDetector(
        store: store,
        coordinator: coordinator,
        tracker: PaneKeyboardActivityTracker(),
        settingsReader: reader,
        catalogSnapshot: { catalog },
        lastFocusedPane: { _ in nil },
        isAppFrontmost: { false },
        onProjectActivity: nil
      )
    }

    /// Minimal Catalog containing one Project → Worktree → Tab → Pane
    /// chain whose pane id equals the test's `P1`. The detector's
    /// `liveResolve` walks this on every `handle(_:)`; without a real
    /// entry the detector silently swallows every notification.
    private static func makeCatalog(
      projectID: ProjectID,
      worktreeID: WorktreeID,
      tabID: TabID,
      paneID: PaneID
    ) -> Catalog {
      let pane = Pane(id: paneID, workingDirectory: "/tmp")
      let tab = Tab(id: tabID, panes: [pane])
      let worktree = Worktree(id: worktreeID, name: "main", path: "/tmp", tabs: [tab])
      let project = Project(
        id: projectID,
        name: "Fixture",
        rootPath: "/tmp",
        worktrees: [worktree]
      )
      return Catalog(projects: [project])
    }
  }
}
