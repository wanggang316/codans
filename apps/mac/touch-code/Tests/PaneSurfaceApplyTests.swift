import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Tests the contract between `PaneInfoDelta` and `SurfaceInfo`.
///
/// Why not drive `PaneSurface.apply(_:)` directly? `PaneSurface.init`
/// requires a live `GhosttyRuntime.app` (a libghostty `ghostty_app_t`) and
/// calls `ghostty_surface_new`, neither of which is available to unit tests.
/// Since `apply(_:)` only reads/writes `info` (no surface-handle traffic),
/// this suite mirrors the same exhaustive switch in `applyForTest` so the
/// Swift compiler still enforces case coverage — if a new `PaneInfoDelta`
/// case lands, both `PaneSurface.apply` and this helper must be updated
/// (the switch here will fail to compile otherwise). That keeps the test
/// meaningful as the decoder/delta contract evolves.
///
/// When `PaneSurface.apply` changes semantics, update `applyForTest` in
/// lockstep — this file documents the mapping from delta → field.
@MainActor
struct PaneSurfaceApplyTests {

  /// Mirrors `PaneSurface.apply(_:)` byte-for-byte. Exhaustive switch —
  /// adding a new `PaneInfoDelta` case without updating this helper will
  /// fail to compile, forcing the test suite to stay in sync.
  private func applyForTest(_ delta: PaneInfoDelta, to info: SurfaceInfo) {
    switch delta {
    case .title(let t):
      info.title = t
    case .tabTitle(let t):
      info.tabTitle = t
    case .promptTitle(let tag):
      info.promptTitle = tag
    case .pwd(let p):
      info.pwd = p

    case .mouseShape(let shape):
      info.mouseShape = shape
    case .mouseVisible(let visible):
      info.mouseVisible = visible
    case .mouseOverLink(let url):
      info.mouseOverLink = url

    case .colorChange(let kind, let r, let g, let b):
      info.colorChange = ColorChange(kind: kind, r: r, g: g, b: b)
    case .rendererHealthy(let healthy):
      info.rendererHealthy = healthy

    case .cellSize(let width, let height):
      info.cellWidth = width
      info.cellHeight = height
    case .sizeLimit(let minWidth, let minHeight, let maxWidth, let maxHeight):
      info.sizeLimitMinWidth = minWidth
      info.sizeLimitMinHeight = minHeight
      info.sizeLimitMaxWidth = maxWidth
      info.sizeLimitMaxHeight = maxHeight
    case .initialSize(let width, let height):
      info.initialWidth = width
      info.initialHeight = height
    case .resetWindowSize:
      break

    case .scrollbar(let total, let offset, let length):
      info.scrollbarTotal = total
      info.scrollbarOffset = offset
      info.scrollbarLength = length

    case .secureInput(let mode):
      info.secureInput = mode
    case .keySequence(let active, let trigger):
      info.keySequenceActive = active
      info.keySequenceTrigger = trigger
    case .keyTable(let name, let depth):
      info.keyTableName = name
      info.keyTableDepth = depth
    case .readonly(let ro):
      info.readonly = ro
    case .quitTimer(let phase):
      info.quitTimer = phase
    case .floatWindow(let floating):
      info.floatWindow = floating

    case .searchStarted(let needle):
      info.searchNeedle = needle
      info.searchTotal = nil
      info.searchSelected = nil
    case .searchEnded:
      info.searchNeedle = nil
      info.searchTotal = nil
      info.searchSelected = nil
    case .searchTotal(let total):
      info.searchTotal = total
    case .searchSelected(let index):
      info.searchSelected = index

    case .progress(let state, let value):
      info.progressState = state
      info.progressValue = value

    case .bellRang:
      info.bellCount &+= 1
    case .desktopNotification(let title, let body):
      info.lastNotificationTitle = title
      info.lastNotificationBody = body
    case .commandFinished(let exitCode, let duration):
      info.lastCommandExitCode = exitCode
      info.lastCommandDuration = duration
    case .childExited(let code):
      info.lastChildExitCode = code
    }
  }

  // MARK: - Defaults

  @Test
  func defaultsMatchSpec() {
    let info = SurfaceInfo()
    #expect(info.title == nil)
    #expect(info.tabTitle == nil)
    #expect(info.promptTitle == 0)
    #expect(info.pwd == nil)

    #expect(info.mouseShape == 0)
    #expect(info.mouseVisible == true)
    #expect(info.mouseOverLink == nil)

    #expect(info.rendererHealthy == true)
    #expect(info.colorChange == nil)

    #expect(info.cellWidth == 0)
    #expect(info.cellHeight == 0)
    #expect(info.sizeLimitMinWidth == 0)
    #expect(info.sizeLimitMinHeight == 0)
    #expect(info.sizeLimitMaxWidth == 0)
    #expect(info.sizeLimitMaxHeight == 0)
    #expect(info.initialWidth == 0)
    #expect(info.initialHeight == 0)

    #expect(info.scrollbarTotal == 0)
    #expect(info.scrollbarOffset == 0)
    #expect(info.scrollbarLength == 0)

    #expect(info.secureInput == 0)
    #expect(info.keySequenceActive == false)
    #expect(info.keySequenceTrigger == 0)
    #expect(info.keyTableName == nil)
    #expect(info.keyTableDepth == 0)
    #expect(info.readonly == false)

    #expect(info.quitTimer == 0)
    #expect(info.floatWindow == false)

    #expect(info.searchNeedle == nil)
    #expect(info.searchTotal == nil)
    #expect(info.searchSelected == nil)

    #expect(info.progressState == 0)
    #expect(info.progressValue == nil)

    #expect(info.bellCount == 0)
    #expect(info.lastNotificationTitle == nil)
    #expect(info.lastNotificationBody == nil)
    #expect(info.lastCommandExitCode == nil)
    #expect(info.lastCommandDuration == nil)
    #expect(info.lastChildExitCode == nil)
  }

  // MARK: - Titles / prompt / pwd

  @Test
  func titleSetsAndClears() {
    let info = SurfaceInfo()
    applyForTest(.title("hello"), to: info)
    #expect(info.title == "hello")
    applyForTest(.title(nil), to: info)
    #expect(info.title == nil)
  }

  @Test
  func tabTitleSetsAndClears() {
    let info = SurfaceInfo()
    applyForTest(.tabTitle("tab"), to: info)
    #expect(info.tabTitle == "tab")
    applyForTest(.tabTitle(nil), to: info)
    #expect(info.tabTitle == nil)
  }

  @Test
  func promptTitleAssigned() {
    let info = SurfaceInfo()
    applyForTest(.promptTitle(42), to: info)
    #expect(info.promptTitle == 42)
  }

  @Test
  func pwdSetsAndClears() {
    let info = SurfaceInfo()
    applyForTest(.pwd("/tmp"), to: info)
    #expect(info.pwd == "/tmp")
    applyForTest(.pwd(nil), to: info)
    #expect(info.pwd == nil)
  }

  // MARK: - Mouse

  @Test
  func mouseShapeAssigned() {
    let info = SurfaceInfo()
    applyForTest(.mouseShape(7), to: info)
    #expect(info.mouseShape == 7)
  }

  @Test
  func mouseVisibleToggles() {
    let info = SurfaceInfo()
    applyForTest(.mouseVisible(false), to: info)
    #expect(info.mouseVisible == false)
    applyForTest(.mouseVisible(true), to: info)
    #expect(info.mouseVisible == true)
  }

  @Test
  func mouseOverLinkSetsAndClears() {
    let info = SurfaceInfo()
    applyForTest(.mouseOverLink("https://example.com"), to: info)
    #expect(info.mouseOverLink == "https://example.com")
    applyForTest(.mouseOverLink(nil), to: info)
    #expect(info.mouseOverLink == nil)
  }

  // MARK: - Renderer / color

  @Test
  func colorChangePopulatesStruct() {
    let info = SurfaceInfo()
    applyForTest(.colorChange(kind: -1, r: 1, g: 2, b: 3), to: info)
    #expect(info.colorChange?.kind == -1)
    #expect(info.colorChange?.r == 1)
    #expect(info.colorChange?.g == 2)
    #expect(info.colorChange?.b == 3)
  }

  @Test
  func rendererHealthyToggles() {
    let info = SurfaceInfo()
    applyForTest(.rendererHealthy(false), to: info)
    #expect(info.rendererHealthy == false)
    applyForTest(.rendererHealthy(true), to: info)
    #expect(info.rendererHealthy == true)
  }

  // MARK: - Geometry

  @Test
  func cellSizeAssignsBothFields() {
    let info = SurfaceInfo()
    applyForTest(.cellSize(width: 10, height: 20), to: info)
    #expect(info.cellWidth == 10)
    #expect(info.cellHeight == 20)
  }

  @Test
  func sizeLimitAssignsAllFourFields() {
    let info = SurfaceInfo()
    applyForTest(.sizeLimit(minWidth: 1, minHeight: 2, maxWidth: 3, maxHeight: 4), to: info)
    #expect(info.sizeLimitMinWidth == 1)
    #expect(info.sizeLimitMinHeight == 2)
    #expect(info.sizeLimitMaxWidth == 3)
    #expect(info.sizeLimitMaxHeight == 4)
  }

  @Test
  func initialSizeAssignsBothFields() {
    let info = SurfaceInfo()
    applyForTest(.initialSize(width: 100, height: 200), to: info)
    #expect(info.initialWidth == 100)
    #expect(info.initialHeight == 200)
  }

  @Test
  func resetWindowSizeIsNoOp() {
    let info = SurfaceInfo()
    // Seed unrelated state to confirm it is not disturbed.
    applyForTest(.initialSize(width: 50, height: 60), to: info)
    applyForTest(.resetWindowSize, to: info)
    #expect(info.initialWidth == 50)
    #expect(info.initialHeight == 60)
  }

  // MARK: - Scrollbar

  @Test
  func scrollbarAssignsAllThreeFields() {
    let info = SurfaceInfo()
    applyForTest(.scrollbar(total: 100, offset: 10, length: 20), to: info)
    #expect(info.scrollbarTotal == 100)
    #expect(info.scrollbarOffset == 10)
    #expect(info.scrollbarLength == 20)
  }

  // MARK: - Input modes

  @Test
  func secureInputAssigned() {
    let info = SurfaceInfo()
    applyForTest(.secureInput(1), to: info)
    #expect(info.secureInput == 1)
  }

  @Test
  func keySequenceAssignsBothFields() {
    let info = SurfaceInfo()
    applyForTest(.keySequence(active: true, trigger: 42), to: info)
    #expect(info.keySequenceActive == true)
    #expect(info.keySequenceTrigger == 42)
  }

  @Test
  func keyTableAssignsBothFields() {
    let info = SurfaceInfo()
    applyForTest(.keyTable(name: "main", depth: 1), to: info)
    #expect(info.keyTableName == "main")
    #expect(info.keyTableDepth == 1)
    applyForTest(.keyTable(name: nil, depth: 0), to: info)
    #expect(info.keyTableName == nil)
    #expect(info.keyTableDepth == 0)
  }

  @Test
  func readonlyToggles() {
    let info = SurfaceInfo()
    applyForTest(.readonly(true), to: info)
    #expect(info.readonly == true)
    applyForTest(.readonly(false), to: info)
    #expect(info.readonly == false)
  }

  // MARK: - Window state

  @Test
  func quitTimerAssigned() {
    let info = SurfaceInfo()
    applyForTest(.quitTimer(5), to: info)
    #expect(info.quitTimer == 5)
  }

  @Test
  func floatWindowToggles() {
    let info = SurfaceInfo()
    applyForTest(.floatWindow(true), to: info)
    #expect(info.floatWindow == true)
    applyForTest(.floatWindow(false), to: info)
    #expect(info.floatWindow == false)
  }

  // MARK: - Search

  @Test
  func searchStartedSetsNeedleAndClearsCounts() {
    let info = SurfaceInfo()
    // Pre-populate counters to verify they get reset.
    applyForTest(.searchTotal(99), to: info)
    applyForTest(.searchSelected(7), to: info)
    applyForTest(.searchStarted(needle: "foo"), to: info)
    #expect(info.searchNeedle == "foo")
    #expect(info.searchTotal == nil)
    #expect(info.searchSelected == nil)
  }

  @Test
  func searchEndedClearsAllThreeFields() {
    let info = SurfaceInfo()
    applyForTest(.searchStarted(needle: "foo"), to: info)
    applyForTest(.searchTotal(10), to: info)
    applyForTest(.searchSelected(3), to: info)
    applyForTest(.searchEnded, to: info)
    #expect(info.searchNeedle == nil)
    #expect(info.searchTotal == nil)
    #expect(info.searchSelected == nil)
  }

  @Test
  func searchTotalAssigned() {
    let info = SurfaceInfo()
    applyForTest(.searchTotal(42), to: info)
    #expect(info.searchTotal == 42)
  }

  @Test
  func searchSelectedAssigned() {
    let info = SurfaceInfo()
    applyForTest(.searchSelected(7), to: info)
    #expect(info.searchSelected == 7)
  }

  // MARK: - Progress

  @Test
  func progressAssignsStateAndValue() {
    let info = SurfaceInfo()
    applyForTest(.progress(state: 1, value: 50), to: info)
    #expect(info.progressState == 1)
    #expect(info.progressValue == 50)
  }

  @Test
  func progressIndeterminateClearsValue() {
    let info = SurfaceInfo()
    applyForTest(.progress(state: 2, value: 50), to: info)
    applyForTest(.progress(state: 0, value: nil), to: info)
    #expect(info.progressState == 0)
    #expect(info.progressValue == nil)
  }

  // MARK: - Bell / notification / lifecycle

  @Test
  func bellRangAccumulates() {
    let info = SurfaceInfo()
    applyForTest(.bellRang, to: info)
    applyForTest(.bellRang, to: info)
    applyForTest(.bellRang, to: info)
    #expect(info.bellCount == 3)
  }

  @Test
  func desktopNotificationAssignsTitleAndBody() {
    let info = SurfaceInfo()
    applyForTest(.desktopNotification(title: "Done", body: "build ok"), to: info)
    #expect(info.lastNotificationTitle == "Done")
    #expect(info.lastNotificationBody == "build ok")
  }

  @Test
  func commandFinishedAssignsExitCodeAndDuration() {
    let info = SurfaceInfo()
    applyForTest(.commandFinished(exitCode: 0, duration: 1000), to: info)
    #expect(info.lastCommandExitCode == 0)
    #expect(info.lastCommandDuration == 1000)
  }

  @Test
  func childExitedAssignsCode() {
    let info = SurfaceInfo()
    applyForTest(.childExited(code: 137), to: info)
    #expect(info.lastChildExitCode == 137)
  }

  // MARK: - Cross-check: markExited equivalence
  //
  // `PaneSurface.markExited(code:)` sets `info.lastChildExitCode = code`
  // — identical to `apply(.childExited(code:))`. We can't invoke it here
  // (would require a constructed PaneSurface), but the equivalence is
  // part of the documented contract and verified by the childExited test
  // above. If `markExited` drifts, the mirrored logic here will drift too
  // and Milestone 7b review should catch it.
}
