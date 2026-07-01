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

  // M1: checked-out collision forces Rename AND the rename gate blocks Create
  // with a clear "already exists" message. validationError is now set (not nil).
  @Test
  func branchDraftMatchingCheckedOutBranchSteersToRenameAndSetsGate() async {
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("main")) {
      $0.branchNameDraft = "main"
      $0.branchCollisionKind = .checkedOut
      // Rename gate fires: effectiveResolution(.checkedOut) == .rename + collision.
      $0.validationError = "Branch \"main\" already exists — choose a different name."
      $0.renameGateActive = true
      $0.selectedResolution = .rename
    }
  }

  // M1: dangling + savedDefault = .rename → rename gate fires (blocks Create).
  @Test
  func branchDraftMatchingDanglingBranchWithRenameDefaultSetsGate() async {
    let store = TestStore(initialState: initialState(savedResolutionDefault: .rename)) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("feature/existing")) {
      $0.branchNameDraft = "feature/existing"
      $0.branchCollisionKind = .dangling
      $0.validationError =
        "Branch \"feature/existing\" already exists — choose a different name."
      $0.renameGateActive = true
      $0.selectedResolution = .rename  // savedResolutionDefault = .rename
    }
  }

  // M1: dangling + savedDefault = .reuse → rename gate DOES NOT fire.
  @Test
  func branchDraftMatchingDanglingBranchWithReuseDefaultClearsGate() async {
    let store = TestStore(initialState: initialState(savedResolutionDefault: .reuse)) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("feature/existing")) {
      $0.branchNameDraft = "feature/existing"
      $0.branchCollisionKind = .dangling
      $0.validationError = nil   // effectiveResolution == .reuse → no gate
      $0.selectedResolution = .reuse
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
      // savedResolutionDefault = .rename → gate fires for the normalized name.
      $0.validationError =
        "Branch \"feature/existing\" already exists — choose a different name."
      $0.renameGateActive = true
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
    // collides with a checked-out branch. Rename gate also fires.
    let store = TestStore(initialState: initialState(savedResolutionDefault: .reuse)) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("main")) {
      $0.branchCollisionKind = .checkedOut
      $0.selectedResolution = .rename   // clamped from .reuse
      // Rename gate fires regardless of saved default.
      $0.validationError =
        "Branch \"main\" already exists — choose a different name."
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

  // MARK: - Rename gate: reactive to resolutionChanged (VAL-RENAME-001/002)

  /// Switching inline picker from Rename to Reuse while a dangling collision
  /// exists clears the rename gate (Create becomes enabled).
  @Test
  func resolutionChangedToReuseWhileDanglingClearsGate() async {
    // Start: dangling collision + rename selected → gate is active.
    var state = initialState(savedResolutionDefault: .rename)
    state.branchCollisionKind = .dangling
    state.branchNameDraft = "feature/existing"
    state.selectedResolution = .rename
    state.validationError =
      "Branch \"feature/existing\" already exists — choose a different name."
    state.renameGateActive = true
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    // User switches inline picker to Reuse → gate clears.
    await store.send(.resolutionChanged(.reuse)) {
      $0.selectedResolution = .reuse
      $0.validationError = nil   // gate cleared; Create is now enabled
      $0.renameGateActive = false
    }
  }

  /// Switching inline picker back to Rename while a dangling collision
  /// exists re-activates the rename gate (Create becomes blocked again).
  @Test
  func resolutionChangedBackToRenameWhileDanglingReactivatesGate() async {
    // Start: dangling collision + reuse selected → gate is inactive.
    var state = initialState(savedResolutionDefault: .reuse)
    state.branchCollisionKind = .dangling
    state.branchNameDraft = "feature/existing"
    state.selectedResolution = .reuse
    state.validationError = nil
    state.renameGateActive = false
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    // User switches inline picker to Rename → gate fires.
    await store.send(.resolutionChanged(.rename)) {
      $0.selectedResolution = .rename
      $0.validationError =
        "Branch \"feature/existing\" already exists — choose a different name."
      $0.renameGateActive = true
    }
  }

  /// Rename gate clears when the user types a non-colliding name (VAL-RENAME-001).
  /// Draft is preserved exactly as typed — no auto-substitution (VAL-RENAME-002).
  @Test
  func renameGateClearsWhenUserTypesFreeName() async {
    // Start: checked-out collision → gate active.
    var state = initialState()
    state.branchCollisionKind = .checkedOut
    state.branchNameDraft = "main"
    state.selectedResolution = .rename
    state.validationError =
      "Branch \"main\" already exists — choose a different name."
    state.renameGateActive = true
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    // User types a fresh, non-colliding name.
    await store.send(.branchDraftChanged("feature/new-branch")) {
      $0.branchNameDraft = "feature/new-branch"   // preserved as typed
      $0.branchCollisionKind = .none
      $0.validationError = nil   // gate cleared
      $0.renameGateActive = false
    }
  }

  /// Ownership model de-risk: when the gate is active and the user then types
  /// a name with spaces, the space message must WIN and the gate must drop its
  /// ownership — a subsequent clear can never retract the space message.
  @Test
  func gateDoesNotClobberSpaceErrorWhenTransitioningFromGateActive() async {
    // Start: dangling collision + rename → gate active with its message.
    var state = initialState(savedResolutionDefault: .rename)
    state.branchCollisionKind = .dangling
    state.branchNameDraft = "feature/existing"
    state.selectedResolution = .rename
    state.validationError =
      "Branch \"feature/existing\" already exists — choose a different name."
    state.renameGateActive = true
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    // User types a name with a space → space message owns validationError,
    // gate ownership is dropped so it can't retract this message later.
    await store.send(.branchDraftChanged("feat with space")) {
      $0.branchNameDraft = "feat with space"
      $0.branchCollisionKind = .none
      $0.validationError = "Branch names can't contain spaces."
      $0.renameGateActive = false
    }
    // Now switching resolution must NOT clear the space message (gate is not
    // the owner). resolutionChanged runs applyRenameGate; since collision is
    // .none and renameGateActive is false, validationError is untouched.
    await store.send(.resolutionChanged(.reuse)) {
      $0.selectedResolution = .reuse
      // validationError stays as the space message — gate never owned it.
    }
    #expect(store.state.validationError == "Branch names can't contain spaces.")
  }

  /// The gate's clear must never touch a message owned by another path. Here
  /// applyRenameGate is invoked (via resolutionChanged) while a non-gate error
  /// ("Pick a base ref." shape) sits in validationError and renameGateActive
  /// is false → the message must survive untouched.
  @Test
  func gateClearLeavesForeignValidationMessageUntouched() async {
    var state = initialState()
    state.branchCollisionKind = .none
    state.selectedResolution = .rename
    // A foreign, non-gate message that the gate does NOT own.
    state.validationError = "Pick a base ref."
    state.renameGateActive = false
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.resolutionChanged(.reuse)) {
      $0.selectedResolution = .reuse
      // No change to validationError: renameGateActive == false, so the gate's
      // clear branch is skipped entirely.
    }
    #expect(store.state.validationError == "Pick a base ref.")
  }

  // MARK: - Reuse spec (VAL-REUSE-001 / VAL-CROSS-003)

  /// effectiveResolution for dangling+reuse is .reuse (VAL-REUSE-001).
  /// The spec's reuseExistingBranch is driven directly by effectiveResolution,
  /// so asserting the state before the tap is sufficient; the payload assertion
  /// lives in HierarchySidebarFeature's pending lifecycle tests.
  @Test
  func reuseEffectiveResolutionIsTrueWhenDanglingAndReuseSelected() {
    var state = initialState(savedResolutionDefault: .reuse)
    state.branchCollisionKind = .dangling
    state.selectedResolution = .reuse
    #expect(state.effectiveResolution == .reuse)
    // createButtonTapped derives: reuseExistingBranch = effectiveResolution == .reuse
    // → true. Verified directly on state rather than via action payload extraction.
  }

  /// When effective resolution is .reuse (dangling + reuse), createButtonTapped
  /// emits beginCreate and does NOT block — gate is inactive for Reuse.
  @Test
  func createWithReuseResolutionProceedsWithoutGateBlock() async {
    var state = initialState(savedResolutionDefault: .reuse)
    state.branchNameDraft = "feature/existing"
    state.selectedBaseRef = "origin/main"
    state.branchCollisionKind = .dangling
    state.selectedResolution = .reuse
    state.validationError = nil  // gate not active for .reuse
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.createButtonTapped)
    await store.receive(\.delegate.beginCreate) { _ in }
    // If we reach here without timeout, the spec was emitted (gate didn't block).
    // reuseExistingBranch is derived from effectiveResolution == .reuse (tested above).
  }

  /// A fresh (non-colliding) create does NOT set reuseExistingBranch — git is
  /// the final arbiter if the branch was created elsewhere since the snapshot
  /// (VAL-CROSS-003). Verified via effectiveResolution state.
  @Test
  func freshCreateEffectiveResolutionIsRenameNotReuse() {
    // .none collision → effectiveResolution == .rename regardless of selectedResolution.
    var state = initialState()
    state.branchCollisionKind = .none
    state.selectedResolution = .reuse   // irrelevant when .none
    // effectiveResolution(.none) == .rename → reuseExistingBranch = false in spec.
    #expect(state.effectiveResolution == .rename)
    #expect(state.effectiveResolution != .reuse)
  }

  // MARK: - Submit-time precedence: rename gate before folder-exists (VAL-CROSS-005)

  /// The rename gate (validationError) preempts the folder-exists check. Even
  /// if a folder happened to exist, the rename-collision error fires first.
  @Test
  func renameGatePreemptsCreateButtonTapped() async {
    // A collision + rename resolution → validationError is set reactively.
    // Tapping Create must return early on the validationError guard, not
    // reach the folder-exists check.
    var state = initialState()
    state.branchNameDraft = "main"
    state.selectedBaseRef = "origin/main"
    state.branchCollisionKind = .checkedOut
    state.selectedResolution = .rename
    // Simulate the rename gate already being set by branchDraftChanged.
    state.validationError =
      "Branch \"main\" already exists — choose a different name."
    state.renameGateActive = true
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.createButtonTapped) {
      // validationError unchanged; submitError NOT set (folder-exists not reached).
      $0.validationError =
        "Branch \"main\" already exists — choose a different name."
      $0.submitError = nil
    }
  }

  // MARK: - Rename path honors base ref + fetch (VAL-RENAME-003)

  /// A rename create (fresh, non-colliding) emits beginCreate, proving it
  /// flows through the normal path (no rename gate block, no bypass).
  /// base ref + fetchOrigin are user-controlled state that flow into the spec;
  /// spec field assertions live in the lifecycle integration test.
  @Test
  func renameCreateFlowsThroughNormalPath() async {
    var state = initialState()
    state.branchNameDraft = "feature/renamed"
    state.selectedBaseRef = "origin/develop"
    state.fetchOrigin = true
    state.branchCollisionKind = .none   // non-colliding → fresh create; no gate
    state.validationError = nil
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.createButtonTapped)
    // beginCreate is emitted — no rename gate block; effectiveResolution(.none) = .rename
    // so reuseExistingBranch = false. base ref and fetchOrigin are in state (above).
    await store.receive(\.delegate.beginCreate) { _ in }
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
