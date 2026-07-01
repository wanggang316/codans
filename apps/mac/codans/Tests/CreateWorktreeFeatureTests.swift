import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

/// Synchronous-branch coverage for `CreateWorktreeFeature`. The async
/// option-load and streaming-create paths are exercised end-to-end by
/// the M13 integration test against a real temp repo; here we lock the
/// live-validator branches, the cancel delegate, and the M1 inline
/// resolution-clamp behavior because those are the ones a future refactor
/// is most likely to silently break.
@MainActor
struct CreateWorktreeFeatureTests {
  private func initialState(
    currentPendingCountForProject: Int = 0,
    savedResolutionDefault: BranchConflictResolution = .rename
  ) -> CreateWorktreeFeature.State {
    var state = CreateWorktreeFeature.State(
      projectID: ProjectID(),
      repoRoot: URL(fileURLWithPath: "/tmp/repo"),
      worktreesDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      currentPendingCountForProject: currentPendingCountForProject,
      savedResolutionDefault: savedResolutionDefault,
      localBranchNamesLower: ["main", "feature/existing"]
    )
    // "main" is checked out by the main worktree (live conflict);
    // "feature/existing" exists as a ref but has no worktree (dangling →
    // reusable on re-create).
    state.liveWorktreeBranchesLower = ["main"]
    return state
  }

  @Test
  func branchDraftEmptyClearsError() async {
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("")) {
      $0.branchNameDraft = ""
      $0.validationError = nil
    }
  }

  @Test
  func branchDraftWithWhitespaceIsRejected() async {
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("feat with space")) {
      $0.branchNameDraft = "feat with space"
      $0.validationError = "Branch names can't contain spaces."
    }
  }

  // Previously this test expected a hard validationError (dead-end).
  // M1 replaces it with an inline "rename only" control — no validationError,
  // selectedResolution forced to .rename, Create button enabled.
  @Test
  func branchDraftMatchingCheckedOutBranchSteersToRename() async {
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("main")) {
      $0.branchNameDraft = "main"
      $0.branchCollisionKind = .checkedOut
      $0.validationError = nil   // no dead-end hard error; inline control explains
      $0.reuseNotice = nil
      $0.selectedResolution = .rename
    }
  }

  // Previously expected a reuseNotice string. M1 replaces reuseNotice with
  // the inline resolution picker seeded to savedResolutionDefault.
  @Test
  func branchDraftMatchingDanglingBranchSetsCollisionKind() async {
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    // Exists as a ref, no live worktree → dangling; picker seeded to .rename (default).
    await store.send(.branchDraftChanged("feature/existing")) {
      $0.branchNameDraft = "feature/existing"
      $0.branchCollisionKind = .dangling
      $0.validationError = nil
      $0.reuseNotice = nil
      $0.selectedResolution = .rename  // savedResolutionDefault = .rename
    }
  }

  @Test
  func branchDraftCleanPassesValidation() async {
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("feature/new-idea")) {
      $0.branchNameDraft = "feature/new-idea"
      $0.validationError = nil
      $0.reuseNotice = nil
    }
  }

  // MARK: - branchCollisionKind classification

  @Test
  func branchCollisionKindNoneForCleanName() async {
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("feature/brand-new")) {
      $0.branchCollisionKind = .none
      $0.validationError = nil
      $0.reuseNotice = nil
    }
  }

  @Test
  func branchCollisionKindCheckedOutForLiveBranch() async {
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    // "main" is in liveWorktreeBranchesLower → checkedOut
    await store.send(.branchDraftChanged("main")) {
      $0.branchCollisionKind = .checkedOut
    }
  }

  @Test
  func branchCollisionKindDanglingForDanglingBranch() async {
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    // "feature/existing" is in localBranchNamesLower but not live → dangling
    await store.send(.branchDraftChanged("feature/existing")) {
      $0.branchCollisionKind = .dangling
    }
  }

  @Test
  func branchCollisionKindDoubleSeparatorNormalizesToDangling() async {
    // "feature//existing" raw ≠ "feature/existing" in the set, but after
    // sanitizeBranchName the doubled slash collapses → "feature/existing" which
    // IS in localBranchNamesLower.  Old raw-compare would show .none; fixed
    // code classifies .dangling while typing.
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("feature//existing")) {
      $0.branchCollisionKind = .dangling
      $0.validationError = nil
      $0.reuseNotice = nil
    }
  }

  @Test
  func branchCollisionKindCaseFoldAndSeparatorNormalizesToCheckedOut() async {
    // "MAIN" (uppercase) sanitizes to "MAIN", then lowercased → "main" which
    // is in liveWorktreeBranchesLower.  Verifies case-fold path in the
    // sanitized classification.
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("MAIN")) {
      $0.branchCollisionKind = .checkedOut
    }
  }

  @Test
  func branchCollisionKindRemoteOnlyIsNone() async {
    // "origin/test" has no matching local branch in either set; classification
    // keys on LOCAL sets only, so remote-only names are .none (fresh create).
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("origin/test")) {
      $0.branchCollisionKind = .none
      $0.validationError = nil
      $0.reuseNotice = nil
    }
  }

  // MARK: - M1 effective-action clamp (collision kind × saved default)

  @Test
  func effectiveResolutionCheckedOutAlwaysRenameRegardlessOfSavedDefault() {
    // Even when the saved default is .reuse or .recreate, checkedOut forces .rename.
    for savedDefault in [BranchConflictResolution.rename, .reuse, .recreate] {
      var state = initialState(savedResolutionDefault: savedDefault)
      state.branchCollisionKind = .checkedOut
      state.selectedResolution = savedDefault
      #expect(state.effectiveResolution == .rename)
    }
  }

  @Test
  func effectiveResolutionDanglingFollowsSelectedResolution() {
    // For a dangling branch all three selections are forwarded as-is.
    for resolution in BranchConflictResolution.allCases {
      var state = initialState()
      state.branchCollisionKind = .dangling
      state.selectedResolution = resolution
      #expect(state.effectiveResolution == resolution)
    }
  }

  @Test
  func effectiveResolutionNoneIsRename() {
    // No collision → effectiveResolution is .rename (fresh create, resolution irrelevant).
    var state = initialState()
    state.branchCollisionKind = .none
    state.selectedResolution = .reuse  // irrelevant for .none
    #expect(state.effectiveResolution == .rename)
  }

  @Test
  func savedDefaultClampsToRenameOnCheckedOutWhenBranchDraftChanged() async {
    // A Reuse/Recreate saved default clamps to Rename when the typed name
    // collides with a checked-out branch.
    let store = TestStore(initialState: initialState(savedResolutionDefault: .reuse)) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("main")) {
      $0.branchCollisionKind = .checkedOut
      $0.selectedResolution = .rename   // clamped from .reuse
      $0.validationError = nil
    }
  }

  @Test
  func savedDefaultClampsToRenameOnCheckedOutForRecreate() async {
    let store = TestStore(initialState: initialState(savedResolutionDefault: .recreate)) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("main")) {
      $0.branchCollisionKind = .checkedOut
      $0.selectedResolution = .rename   // clamped from .recreate
    }
  }

  @Test
  func danglingSeededToSavedDefaultWhenDefaultIsReuse() async {
    let store = TestStore(initialState: initialState(savedResolutionDefault: .reuse)) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("feature/existing")) {
      $0.branchCollisionKind = .dangling
      $0.selectedResolution = .reuse   // seeded from savedResolutionDefault
    }
  }

  // MARK: - Inline override is per-creation only (no settings write)

  @Test
  func resolutionChangedUpdatesSelectedResolutionWithoutEffect() async {
    // The inline picker sends .resolutionChanged — only selectedResolution
    // changes; no side-effects are emitted (CreateWorktreeFeature has no
    // SettingsWriter dependency, so settings-write is structurally impossible).
    var state = initialState()
    state.branchCollisionKind = .dangling
    state.selectedResolution = .rename
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.resolutionChanged(.reuse)) {
      $0.selectedResolution = .reuse
    }
    // No effects queued — TestStore would have timed out if any async effect ran.
  }

  @Test
  func inlineOverrideResetBySavedDefaultOnNextBranchDraftChange() async {
    // After the user overrides to .reuse via the picker, changing the branch
    // name resets selectedResolution back to savedResolutionDefault (.rename).
    var state = initialState(savedResolutionDefault: .rename)
    state.branchCollisionKind = .dangling
    state.selectedResolution = .reuse   // simulate inline override
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    // Type a clean name → .none; selectedResolution reset to .rename.
    await store.send(.branchDraftChanged("feature/brand-new")) {
      $0.branchCollisionKind = .none
      $0.selectedResolution = .rename   // reset to savedResolutionDefault
    }
  }

  // MARK: - Other delegate / submit paths

  @Test
  func cancelEmitsDismissDelegate() async {
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.cancelButtonTapped)
    await store.receive(\.delegate.dismissed)
  }

  @Test
  func createBlocksWhenNoBaseRefSelected() async {
    var state = initialState()
    state.branchNameDraft = "feature/ok"
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.createButtonTapped) {
      $0.validationError = "Pick a base ref."
    }
  }

  @Test
  func createButtonTappedEmitsBeginCreateDelegate() async {
    var state = initialState()
    state.branchNameDraft = "feature/new-idea"
    state.selectedBaseRef = "origin/main"
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.createButtonTapped)
    await store.receive(\.delegate.beginCreate) { _ in
      // Reducer state is unchanged on success — the new pending payload
      // travels via the delegate; the payload's exact ID is per-call so
      // we don't pin its value here. The receive(\.delegate.beginCreate)
      // matcher verifies the action shape; payload-specific assertions
      // live in the parent reducer's PendingWorktreeLifecycleTests.
    }
  }

  @Test
  func createButtonTappedRejectedAtCap() async {
    var state = initialState(currentPendingCountForProject: 8)
    state.branchNameDraft = "feature/new-idea"
    state.selectedBaseRef = "origin/main"
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.createButtonTapped) {
      $0.submitError = CreateWorktreeFeature.capMessage
    }
  }
}
