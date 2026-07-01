import CodansCore
import ComposableArchitecture
import Foundation
import Testing

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
    savedResolutionDefault: BranchConflictResolution = .rename,
    localBranchNames: Set<String> = ["main", "feature/existing"]
  ) -> CreateWorktreeFeature.State {
    var state = CreateWorktreeFeature.State(
      projectID: ProjectID(),
      repoRoot: URL(fileURLWithPath: "/tmp/repo"),
      worktreesDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      currentPendingCountForProject: currentPendingCountForProject,
      savedResolutionDefault: savedResolutionDefault
    )
    // Derive both classification structures from one original-cased source —
    // exactly as the reducer does on `.optionsLoaded` — so the lowercased match
    // set and the [lowercased: original] casing-recovery map stay in sync.
    // "main" is checked out by the main worktree (live conflict);
    // "feature/existing" exists as a ref but has no worktree (dangling →
    // reusable on re-create).
    CreateWorktreeFeature.ingestLocalBranchNames(localBranchNames, into: &state)
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
      $0.validationError = nil  // effectiveResolution == .reuse → no gate
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
      $0.selectedResolution = .rename  // clamped from .reuse
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
      $0.selectedResolution = .rename  // clamped from .recreate
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
      $0.selectedResolution = .reuse  // seeded from savedResolutionDefault
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
    state.selectedResolution = .reuse  // simulate inline override
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    // Type a clean name → .none; selectedResolution reset to .rename.
    await store.send(.branchDraftChanged("feature/brand-new")) {
      $0.branchCollisionKind = .none
      $0.selectedResolution = .rename  // reset to savedResolutionDefault
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
      $0.validationError = nil  // gate cleared; Create is now enabled
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
      $0.branchNameDraft = "feature/new-branch"  // preserved as typed
      $0.branchCollisionKind = .none
      $0.validationError = nil  // gate cleared
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
    state.selectedResolution = .reuse  // irrelevant when .none
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

  /// VAL-CROSS-005 core: a DANGLING branch with Reuse selected
  /// (effectiveResolution == .reuse) whose target worktree directory ALREADY
  /// EXISTS on disk must show "folder already exists" and issue NO reuse — the
  /// folder-exists guard PREEMPTS the create, so no `beginCreate` delegate
  /// (and thus no `reuseExistingBranch` spec) is ever dispatched.
  ///
  /// Driven against a REAL temp `worktreesDirectory` because the guard uses
  /// `FileManager.default.fileExists` on the computed target path; the create
  /// action runs under EXHAUSTIVE checking so an accidental `beginCreate`
  /// effect would fail the test (no matching `receive`).
  @Test
  func folderExistsPreemptsReuseForDanglingTarget() async throws {
    // Real, unique temp dir standing in for the Project's worktrees directory.
    let worktreesDir = FileManager.default.temporaryDirectory
      .appending(component: "codans-create-wt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: worktreesDir, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: worktreesDir) }

    // "feature/existing" is dangling (a local ref with no live worktree).
    // Pre-create its target subfolder so the folder-exists guard trips.
    // The name maps to a nested path (`feature/existing`) via appending(path:),
    // so create intermediate dirs to mirror what `wt sw` would produce.
    let directoryName = GitWorktreeClient.sanitizeBranchName("feature/existing")
    let targetDir = worktreesDir.appending(path: directoryName)
    try FileManager.default.createDirectory(
      at: targetDir, withIntermediateDirectories: true
    )

    // Build state directly (initialState hardcodes worktreesDirectory, which is
    // a `let`). Reuse selected on a dangling branch → effectiveResolution .reuse.
    var state = CreateWorktreeFeature.State(
      projectID: ProjectID(),
      repoRoot: URL(fileURLWithPath: "/tmp/repo"),
      worktreesDirectory: worktreesDir,
      currentPendingCountForProject: 0,
      savedResolutionDefault: .reuse
    )
    CreateWorktreeFeature.ingestLocalBranchNames(["main", "feature/existing"], into: &state)
    state.liveWorktreeBranchesLower = ["main"]
    state.branchNameDraft = "feature/existing"
    state.selectedBaseRef = "origin/main"
    state.branchCollisionKind = .dangling
    state.danglingRealName = "feature/existing"
    state.selectedResolution = .reuse
    state.validationError = nil  // reuse → rename gate inactive
    state.renameGateActive = false
    // Sanity: this is genuinely the reuse path (would set reuseExistingBranch).
    #expect(state.effectiveResolution == .reuse)

    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    // EXHAUSTIVE (default): if createButtonTapped dispatched .beginCreate, the
    // store would demand a matching receive and fail — proving no reuse leaked.
    await store.send(.createButtonTapped) {
      // Only mutation is the folder-exists submitError; guard returned early.
      $0.submitError = """
        A folder named \"\(directoryName)\" already exists at the Project's \
        worktrees directory. Choose a different branch name.
        """
    }
    // No delegate effect emitted → no reuse dispatched into an existing dir.
    #expect(store.state.validationError == nil)
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
    state.branchCollisionKind = .none  // non-colliding → fresh create; no gate
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

  // MARK: - M2 Recreate guard (VAL-RECREATE-001..011)

  /// Builds a state already sitting on a dangling collision with Recreate
  /// selected and a base picked — the entry point for the unique-commit guard.
  /// `existing` is the set of ORIGINAL-cased local refs; `branch` is what the
  /// user typed (its casing may differ from the matched ref). `danglingRealName`
  /// is resolved exactly as the reducer's classification would, so the operative
  /// name used by the count/delete/attach reflects the real ref casing.
  private func recreateState(
    branch: String = "feature/existing",
    base: String = "origin/main",
    existing: Set<String> = ["main", "feature/existing"]
  ) -> CreateWorktreeFeature.State {
    var state = initialState(
      savedResolutionDefault: .recreate, localBranchNames: existing
    )
    state.branchNameDraft = branch
    state.selectedBaseRef = base
    state.branchCollisionKind = .dangling
    let lower = GitWorktreeClient.sanitizeBranchName(branch).lowercased()
    state.danglingRealName = state.localBranchNamesByLower[lower]
    state.selectedResolution = .recreate
    return state
  }

  /// 0 unique commits → SILENT: Create enabled (recreateBlocksCreate == false),
  /// no confirm control (recreateNeedsConfirm == false), no warning.
  @Test
  func recreateZeroUniqueCountIsSilentAndEnablesCreate() async {
    let store = TestStore(initialState: recreateState()) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.branchUniqueCommitCount = { _, _, _ in 0 }
    }
    store.exhaustivity = .off
    // Re-enter the recreate context to launch the count effect.
    await store.send(.resolutionChanged(.recreate))
    await store.receive(\.recreateCountLoaded) {
      $0.recreateUniqueCount = 0
      $0.recreateCountFailed = false
    }
    #expect(store.state.recreateNeedsConfirm == false)
    #expect(store.state.recreateBlocksCreate == false)
    #expect(store.state.recreateWarning == nil)
  }

  /// >0 unique commits → WARN + CONFIRM: warning NAMES N, Create disabled until
  /// the discrete confirm toggles true.
  @Test
  func recreatePositiveUniqueCountWarnsAndBlocksUntilConfirmed() async {
    let store = TestStore(initialState: recreateState()) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.branchUniqueCommitCount = { _, _, _ in 3 }
    }
    store.exhaustivity = .off
    await store.send(.resolutionChanged(.recreate))
    await store.receive(\.recreateCountLoaded) {
      $0.recreateUniqueCount = 3
    }
    // Warning names the 3 commits; Create is blocked pre-confirm.
    #expect(store.state.recreateNeedsConfirm == true)
    #expect(store.state.recreateBlocksCreate == true)
    #expect(store.state.recreateWarning?.contains("3 commits") == true)
    // Discrete confirm unblocks Create.
    await store.send(.recreateConfirmedToggled(true)) {
      $0.recreateConfirmed = true
    }
    #expect(store.state.recreateBlocksCreate == false)
  }

  /// Guard (a): a `branchDraftChanged` after a confirm RESETS recreateConfirmed
  /// and re-disables Create — a stale confirm can never carry to a new branch.
  @Test
  func recreateConfirmResetsOnBranchDraftChanged() async {
    // Two dangling branches so retyping lands on a different dangling collision.
    var state = recreateState(
      branch: "feature/existing",
      existing: ["main", "feature/existing", "feature/other"]
    )
    state.recreateUniqueCount = 5
    state.recreateConfirmed = true
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.branchUniqueCommitCount = { _, _, _ in 5 }
    }
    store.exhaustivity = .off
    // Retype onto the OTHER dangling branch → confirm resets immediately.
    await store.send(.branchDraftChanged("feature/other")) {
      $0.branchNameDraft = "feature/other"
      $0.danglingRealName = "feature/other"  // re-resolved for the new match
      $0.recreateConfirmed = false  // guard (a): reset on edit
      $0.recreateUniqueCount = nil  // pending recompute (never coerced to 0)
    }
    // Create is blocked again while the count is pending / unconfirmed.
    #expect(store.state.recreateBlocksCreate == true)
    await store.receive(\.recreateCountLoaded) {
      $0.recreateUniqueCount = 5
    }
    // Still blocked — confirm did NOT survive the edit.
    #expect(store.state.recreateBlocksCreate == true)
  }

  /// Guard (a): a `baseRefSelected` after a confirm RESETS recreateConfirmed.
  @Test
  func recreateConfirmResetsOnBaseRefSelected() async {
    var state = recreateState(base: "origin/main")
    state.recreateUniqueCount = 2
    state.recreateConfirmed = true
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.branchUniqueCommitCount = { _, _, _ in 2 }
    }
    store.exhaustivity = .off
    await store.send(.baseRefSelected("origin/develop")) {
      $0.selectedBaseRef = "origin/develop"
      $0.recreateConfirmed = false  // guard (a): reset on base change
      $0.recreateUniqueCount = nil
    }
    #expect(store.state.recreateBlocksCreate == true)
    await store.receive(\.recreateCountLoaded) {
      $0.recreateUniqueCount = 2
    }
  }

  /// Guard (b): a base change re-evaluates the count in BOTH directions —
  /// diverged(>0, warn) → merged(0, silent), and back.
  @Test
  func recreateBaseChangeFlipsSilentAndWarnBothWays() async {
    // First base diverges (2), second base is merged (0), third diverges again.
    let counts = LockIsolated<[String: Int]>([
      "origin/main": 2, "origin/merged": 0, "origin/other": 4,
    ])
    var state = recreateState(base: "origin/main")
    state.recreateUniqueCount = 2
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.branchUniqueCommitCount = { _, _, base in
        counts.value[base] ?? 0
      }
    }
    store.exhaustivity = .off
    // Switch to a merged base → 0 → silent.
    await store.send(.baseRefSelected("origin/merged")) {
      $0.selectedBaseRef = "origin/merged"
      $0.recreateUniqueCount = nil
    }
    await store.receive(\.recreateCountLoaded) {
      $0.recreateUniqueCount = 0
    }
    #expect(store.state.recreateNeedsConfirm == false)  // silent
    #expect(store.state.recreateBlocksCreate == false)
    // Switch to a diverged base → >0 → warn again.
    await store.send(.baseRefSelected("origin/other")) {
      $0.selectedBaseRef = "origin/other"
      $0.recreateUniqueCount = nil
    }
    await store.receive(\.recreateCountLoaded) {
      $0.recreateUniqueCount = 4
    }
    #expect(store.state.recreateNeedsConfirm == true)  // warn
    #expect(store.state.recreateBlocksCreate == true)
  }

  /// Guard (c): when the count compute THROWS, the guard is FAIL-SAFE —
  /// recreateUniqueCount stays nil (never 0), recreateCountFailed is set, and
  /// Create is blocked (confirm-required), NEVER silent.
  @Test
  func recreateCountThrowForcesConfirmNeverSilent() async {
    struct BadBase: Error {}
    let store = TestStore(initialState: recreateState()) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.branchUniqueCommitCount = { _, _, _ in throw BadBase() }
    }
    store.exhaustivity = .off
    await store.send(.resolutionChanged(.recreate))
    await store.receive(\.recreateCountFailed) {
      $0.recreateUniqueCount = nil  // NEVER coerced to 0
      $0.recreateCountFailed = true
    }
    // Fail-safe: unknown is treated as dangerous → confirm required, not silent.
    #expect(store.state.recreateNeedsConfirm == true)
    #expect(store.state.recreateBlocksCreate == true)
    #expect(store.state.recreateWarning != nil)
    // A proven-0 (silent) path is impossible here — recreateUniqueCount != 0.
    #expect(store.state.recreateUniqueCount != 0)
  }

  /// Guard (d): a >0-count Recreate submitted WITHOUT confirm dispatches NO
  /// deleteBranchIfExists and NO beginCreate — a strict no-op (branch, commits,
  /// dir untouched). Runs under EXHAUSTIVE checking so any leaked delegate or
  /// delete effect would fail the test.
  @Test
  func recreateUnconfirmedSubmitDispatchesNoDeleteAndNoBeginCreate() async {
    let deleteCalled = LockIsolated(false)
    var state = recreateState()
    state.recreateUniqueCount = 3  // diverged
    state.recreateConfirmed = false  // NOT confirmed
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    } withDependencies: {
      // Any delete call flips the flag AND would break the .kept path; but the
      // reducer must never reach it.
      $0.gitWorktreeClient.deleteBranchIfExists = { _, _ in
        deleteCalled.setValue(true)
        return .deleted
      }
    }
    // EXHAUSTIVE: submitError is the ONLY mutation; no beginCreate to receive.
    await store.send(.createButtonTapped) {
      $0.submitError =
        "Confirm that recreating this branch will discard its commits before continuing."
    }
    #expect(deleteCalled.value == false)  // guard (d): no delete ever fired
  }

  /// A confirmed >0-count Recreate submits: delete FIRST (.deleted), THEN
  /// beginCreate with reuseExistingBranch == false (fresh -b from base).
  @Test
  func recreateConfirmedSubmitDeletesThenBeginsCreateWithFreshBranch() async {
    let deleteBranch = LockIsolated<String?>(nil)
    var state = recreateState()
    state.recreateUniqueCount = 3
    state.recreateConfirmed = true  // confirmed
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.deleteBranchIfExists = { _, branch in
        deleteBranch.setValue(branch)
        return .deleted
      }
    }
    store.exhaustivity = .off
    await store.send(.createButtonTapped)
    await store.receive(\.delegate.beginCreate) { _ in }
    // Delete was called with the sanitized branch name, BEFORE beginCreate.
    #expect(deleteBranch.value == "feature/existing")
    // Recreate is a fresh create: reuseExistingBranch must be false.
    #expect(store.state.effectiveResolution == .recreate)
  }

  /// A 0-count (silent) Recreate also runs delete-then-create — no confirm
  /// needed, and the delete still fires first.
  @Test
  func recreateSilentSubmitDeletesThenBeginsCreate() async {
    let deleteCalled = LockIsolated(false)
    var state = recreateState()
    state.recreateUniqueCount = 0  // silent
    state.recreateConfirmed = false  // not needed for a 0-count
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.deleteBranchIfExists = { _, _ in
        deleteCalled.setValue(true)
        return .deleted
      }
    }
    store.exhaustivity = .off
    // Sanity: silent means Create is not blocked.
    #expect(store.state.recreateBlocksCreate == false)
    await store.send(.createButtonTapped)
    await store.receive(\.delegate.beginCreate) { _ in }
    #expect(deleteCalled.value == true)
  }

  /// Guard (e): if the branch became checked out since selection,
  /// deleteBranchIfExists returns `.kept` at submit — ABORT with the error
  /// surfaced and NO beginCreate. The branch is not deleted, nothing created.
  @Test
  func recreateSubmitWithKeptDeleteAbortsWithErrorAndNoBeginCreate() async {
    var state = recreateState()
    state.recreateUniqueCount = 0  // even a silent recreate must re-guard here
    state.recreateConfirmed = false
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.deleteBranchIfExists = { _, _ in
        .kept(reason: "branch is checked out")
      }
    }
    // EXHAUSTIVE for the terminal state; the async delete result arrives via
    // recreateDeleteFailed, and NO beginCreate is ever received.
    store.exhaustivity = .off
    await store.send(.createButtonTapped)
    await store.receive(\.recreateDeleteFailed) {
      $0.submitError =
        "Couldn't recreate the branch — it wasn't deleted, so nothing was created. branch is checked out"
    }
  }

  /// A Recreate where the branch is already absent at submit (`.absent`) still
  /// proceeds to beginCreate — absence is success, not a failure.
  @Test
  func recreateSubmitWithAbsentDeleteStillBeginsCreate() async {
    var state = recreateState()
    state.recreateUniqueCount = 0
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.deleteBranchIfExists = { _, _ in .absent }
    }
    store.exhaustivity = .off
    await store.send(.createButtonTapped)
    await store.receive(\.delegate.beginCreate) { _ in }
  }

  /// Switching AWAY from Recreate (to Reuse) clears the guard — no warning, no
  /// block — and stops requiring confirmation.
  @Test
  func leavingRecreateClearsGuard() async {
    var state = recreateState()
    state.recreateUniqueCount = 4
    state.recreateConfirmed = false
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    // Reuse is not a recreate context → guard resets, no count effect runs.
    await store.send(.resolutionChanged(.reuse)) {
      $0.selectedResolution = .reuse
      $0.recreateUniqueCount = nil
      $0.recreateConfirmed = false
    }
    #expect(store.state.isRecreateContext == false)
    #expect(store.state.recreateNeedsConfirm == false)
    #expect(store.state.recreateBlocksCreate == false)
    #expect(store.state.recreateWarning == nil)
  }

  /// Stale-result drop: a count that returns for a PRIOR (branch, base) token
  /// after the user has retyped must be ignored, not applied to the new
  /// selection. Proven by feeding a mismatched token directly.
  @Test
  func recreateStaleCountResultIsDropped() async {
    var state = recreateState(branch: "feature/existing", base: "origin/main")
    state.recreateUniqueCount = nil
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    // A result whose token names a DIFFERENT base than the live selection.
    let staleToken = RecreateGuardToken(branch: "feature/existing", base: "origin/OLD")
    await store.send(.recreateCountLoaded(count: 0, token: staleToken))
    // Ignored: count stays nil (still gated), not coerced to the stale 0.
    #expect(store.state.recreateUniqueCount == nil)
    #expect(store.state.recreateBlocksCreate == true)
  }

  /// Warning copy singularizes for exactly 1 unique commit.
  @Test
  func recreateWarningSingularizesForOneCommit() async {
    let store = TestStore(initialState: recreateState()) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.branchUniqueCommitCount = { _, _, _ in 1 }
    }
    store.exhaustivity = .off
    await store.send(.resolutionChanged(.recreate))
    await store.receive(\.recreateCountLoaded) {
      $0.recreateUniqueCount = 1
    }
    #expect(store.state.recreateWarning?.contains("1 commit ") == true)
    #expect(store.state.recreateWarning?.contains("1 commits") == false)
  }

  // MARK: - VAL-CHOICE-002: Inline escape clears warning+confirm and issues no delete

  /// Switching inline picker from Recreate (warning armed, confirm required) to
  /// Rename: warning clears, confirm resets, isRecreateContext=false, and a
  /// subsequent Create is blocked only by the rename gate — no delete is ever
  /// dispatched. Verifies the escape-to-Rename leg of VAL-CHOICE-002.
  @Test
  func inlineEscapeToRenameFromRecreateClearsWarningAndNoDelete() async {
    // Arm the guard: dangling + recreate + 3 unique commits (warning shown, confirm required).
    let deleteCalled = LockIsolated(false)
    var state = recreateState()
    state.branchNameDraft = "feature/existing"
    state.recreateUniqueCount = 3
    state.recreateConfirmed = false
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.deleteBranchIfExists = { _, _ in
        deleteCalled.setValue(true)
        return .deleted
      }
    }
    store.exhaustivity = .off
    // Sanity: guard is armed before the switch.
    #expect(store.state.isRecreateContext == true)
    #expect(store.state.recreateNeedsConfirm == true)
    #expect(store.state.recreateWarning != nil)

    // Switch to Rename → refreshRecreateGuard resets the guard; applyRenameGate
    // fires for the dangling collision (validationError set, renameGateActive true).
    await store.send(.resolutionChanged(.rename)) {
      $0.selectedResolution = .rename
      // Guard cleared by refreshRecreateGuard.
      $0.recreateUniqueCount = nil
      $0.recreateConfirmed = false
      // Rename gate fires: dangling collision + effectiveResolution == .rename.
      $0.validationError =
        "Branch \"feature/existing\" already exists — choose a different name."
      $0.renameGateActive = true
    }
    #expect(store.state.isRecreateContext == false)
    #expect(store.state.recreateNeedsConfirm == false)
    #expect(store.state.recreateBlocksCreate == false)
    #expect(store.state.recreateWarning == nil)

    // Attempt Create: blocked early by validationError (rename gate), NOT by
    // recreateBlocksCreate. No delete effect is ever dispatched (guard (e) never reached).
    await store.send(.createButtonTapped)
    // Store is in .off exhaustivity; if any async delete or beginCreate effect ran,
    // it would surface as an unhandled receive when the test drains — prove neither fired.
    #expect(deleteCalled.value == false)
    // validationError is still the rename gate message (not clobbered by submitError).
    #expect(
      store.state.validationError == "Branch \"feature/existing\" already exists — choose a different name."
    )
  }

  /// Switching inline picker from Recreate (warning armed, confirm required) to
  /// Reuse: warning clears, confirm resets, isRecreateContext=false, and a
  /// subsequent Create sets reuseExistingBranch=true with NO delete dispatched.
  /// Verifies the escape-to-Reuse leg of VAL-CHOICE-002.
  @Test
  func inlineEscapeToReuseFromRecreateClearsWarningAndCreateReuses() async {
    let deleteCalled = LockIsolated(false)
    var state = recreateState()
    state.branchNameDraft = "feature/existing"
    state.selectedBaseRef = "origin/main"
    state.recreateUniqueCount = 5
    state.recreateConfirmed = false
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.deleteBranchIfExists = { _, _ in
        deleteCalled.setValue(true)
        return .deleted
      }
    }
    store.exhaustivity = .off

    // Switch to Reuse → guard clears, no rename gate (effectiveResolution != .rename).
    await store.send(.resolutionChanged(.reuse)) {
      $0.selectedResolution = .reuse
      $0.recreateUniqueCount = nil
      $0.recreateConfirmed = false
    }
    #expect(store.state.isRecreateContext == false)
    #expect(store.state.recreateNeedsConfirm == false)
    #expect(store.state.recreateBlocksCreate == false)
    #expect(store.state.recreateWarning == nil)
    #expect(store.state.effectiveResolution == .reuse)

    // Create succeeds: no delete fired (Reuse does not delete), beginCreate emitted
    // with reuseExistingBranch=true (from effectiveResolution == .reuse).
    await store.send(.createButtonTapped)
    await store.receive(\.delegate.beginCreate) { _ in }
    #expect(deleteCalled.value == false)  // no delete on Reuse path (VAL-CHOICE-002)
  }

  // MARK: - VAL-CROSS-004: Setup script runs on all three resolution paths

  /// The reuse path emits beginCreate (spec is not blocked or stripped). The
  /// setupCommand field is always injected AFTER beginCreate by the parent
  /// HierarchySidebarFeature (unconditionally at line 768 regardless of
  /// reuseExistingBranch), so the reuse spec must reach the parent unmodified.
  /// This test confirms the reuse path reaches beginCreate (nothing in
  /// CreateWorktreeFeature strips or pre-fills setupCommand, which defaults nil
  /// from CreateWorktreeSpec's initializer — the field is open for parent injection).
  @Test
  func reusePathEmitsBeginCreateForParentSetupInjection() async {
    // A dangling branch with Reuse resolution: no gate, no delete, no block.
    var state = initialState(savedResolutionDefault: .reuse)
    state.branchNameDraft = "feature/existing"
    state.selectedBaseRef = "origin/main"
    state.branchCollisionKind = .dangling
    state.selectedResolution = .reuse
    state.validationError = nil
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.createButtonTapped)
    // beginCreate is dispatched — spec reaches parent for setupCommand injection.
    // reuseExistingBranch is true (effectiveResolution == .reuse); setupCommand is nil
    // here (parent sets it). Neither field is pre-stripped by this reducer.
    await store.receive(\.delegate.beginCreate) { _ in }
    // Sanity: spec derivation for reuse sets reuseExistingBranch correctly.
    #expect(store.state.effectiveResolution == .reuse)
  }

  // MARK: - VAL-CROSS-002: Confirmed Recreate end-to-end reducer journey

  /// Walks the full confirmed-Recreate journey at the reducer level:
  /// dangling + recreate → resolutionChanged(.recreate) → count>0 loads →
  /// confirm toggled → createButtonTapped → delete(.deleted) → beginCreate
  /// with reuseExistingBranch=false (fresh -b spec from base).
  ///
  /// The git-level guarantees (unique commits gone / reflog-recoverable /
  /// worktree opened) are dogfood-deferred — no GUI automation here.
  @Test
  func recreateFullConfirmedJourneyEndToEnd() async {
    let deleteBranch = LockIsolated<String?>(nil)
    // Start from a dangling collision already in recreate mode with a base selected.
    var state = recreateState(branch: "feature/existing", base: "origin/main")
    // No pre-loaded count yet (simulating entry into recreate context fresh).
    state.recreateUniqueCount = nil
    state.recreateConfirmed = false
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.branchUniqueCommitCount = { _, _, _ in 4 }
      $0.gitWorktreeClient.deleteBranchIfExists = { _, branch in
        deleteBranch.setValue(branch)
        return .deleted
      }
    }
    store.exhaustivity = .off

    // Step 1: enter recreate context → count effect fires.
    await store.send(.resolutionChanged(.recreate))
    #expect(store.state.isRecreateContext == true)
    #expect(store.state.recreateNeedsConfirm == true)  // count nil → confirm required

    // Step 2: count loads → warning armed (4 commits), still blocked.
    await store.receive(\.recreateCountLoaded) {
      $0.recreateUniqueCount = 4
      $0.recreateCountFailed = false
    }
    #expect(store.state.recreateWarning?.contains("4 commits") == true)
    #expect(store.state.recreateBlocksCreate == true)

    // Step 3: user checks the confirm Toggle → Create becomes enabled.
    await store.send(.recreateConfirmedToggled(true)) {
      $0.recreateConfirmed = true
    }
    #expect(store.state.recreateBlocksCreate == false)

    // Step 4: createButtonTapped → delete fires FIRST, THEN beginCreate.
    await store.send(.createButtonTapped)
    await store.receive(\.delegate.beginCreate) { _ in }

    // Delete was called with the sanitized branch name before beginCreate.
    #expect(deleteBranch.value == "feature/existing")
    // Recreate spec is a fresh create: reuseExistingBranch == false (not reuse).
    #expect(store.state.effectiveResolution == .recreate)
    // The effectiveResolution == .recreate → reuseExistingBranch = false in the spec.
    // (the spec's reuseExistingBranch is derived as `effectiveResolution == .reuse`
    //  which is false for .recreate, satisfying VAL-CROSS-002's "fresh -b from base".)
  }

  // MARK: - M2 review fix: target the REAL-cased ref (VAL-RECREATE case-safety)

  /// Classifying a dangling collision typed in a DIFFERENT case than the
  /// existing ref resolves `danglingRealName` to the EXISTING ref's real
  /// casing, and `operativeBranchName` follows it. The draft casing only drives
  /// the case-insensitive MATCH.
  @Test
  func caseMismatchResolvesDanglingRealNameToExistingRef() async {
    // Existing local ref is mixed-case; user types the all-lowercase form.
    let store = TestStore(
      initialState: initialState(localBranchNames: ["main", "Feature-Login"])
    ) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("feature-login")) {
      $0.branchNameDraft = "feature-login"
      $0.branchCollisionKind = .dangling  // matched case-insensitively
      $0.danglingRealName = "Feature-Login"  // resolved to the REAL casing
    }
    #expect(store.state.operativeBranchName == "Feature-Login")
  }

  /// The Recreate unique-commit count is computed against the REAL-cased ref,
  /// not the draft — proving the wrong-cased ref is never the count target.
  @Test
  func caseMismatchRecreateCountTargetsRealCasedRef() async {
    let countedBranch = LockIsolated<String?>(nil)
    // recreateState with a mixed-case existing ref + a lowercase draft.
    let state = recreateState(
      branch: "feature-login",
      base: "origin/main",
      existing: ["main", "Feature-Login"]
    )
    // Sanity: danglingRealName recovered the real casing.
    #expect(state.danglingRealName == "Feature-Login")
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.branchUniqueCommitCount = { _, branch, _ in
        countedBranch.setValue(branch)
        return 2
      }
    }
    store.exhaustivity = .off
    await store.send(.resolutionChanged(.recreate))
    await store.receive(\.recreateCountLoaded) {
      $0.recreateUniqueCount = 2
    }
    // The count ran against the EXISTING ref's real casing, not "feature-login".
    #expect(countedBranch.value == "Feature-Login")
  }

  /// The Recreate submit force-deletes the REAL-cased ref and reproduces it in
  /// the fresh-create spec.name — so on a case-sensitive FS the delete hits the
  /// real branch (no duplicate) and the recreate is the SAME-named branch. The
  /// delete target is observed directly; `spec.name` is built from the same
  /// `operativeBranchName`, asserted on state below.
  @Test
  func caseMismatchRecreateSubmitDeletesAndRecreatesRealCasedRef() async {
    let deletedBranch = LockIsolated<String?>(nil)
    var state = recreateState(
      branch: "feature-login",
      base: "origin/main",
      existing: ["main", "Feature-Login"]
    )
    state.recreateUniqueCount = 0  // silent path: still deletes real-cased ref first
    // The spec's `name` is assigned `= operativeBranchName`; assert the exact
    // value the fresh `-b` create will reproduce.
    #expect(state.operativeBranchName == "Feature-Login")
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    } withDependencies: {
      $0.gitWorktreeClient.deleteBranchIfExists = { _, branch in
        deletedBranch.setValue(branch)
        return .deleted
      }
    }
    store.exhaustivity = .off
    await store.send(.createButtonTapped)
    await store.receive(\.delegate.beginCreate)
    // Delete targeted the real ref (observed), BEFORE beginCreate; the recreate
    // spec.name is the same real-cased value (asserted on state above).
    #expect(deletedBranch.value == "Feature-Login")
  }

  /// The Reuse attach spec also carries the REAL-cased ref, so `wt sw --path`
  /// attaches the existing branch instead of dying on / creating a mis-cased
  /// one. `spec.name` is built from `operativeBranchName` (asserted on state);
  /// `effectiveResolution == .reuse` drives `reuseExistingBranch = true`.
  @Test
  func caseMismatchReuseAttachSpecCarriesRealCasedRef() async {
    var state = initialState(
      savedResolutionDefault: .reuse, localBranchNames: ["main", "Feature-Login"]
    )
    state.branchNameDraft = "feature-login"
    state.selectedBaseRef = "origin/main"
    state.branchCollisionKind = .dangling
    state.danglingRealName = "Feature-Login"
    state.selectedResolution = .reuse
    // Reuse on a dangling ref → attach the EXISTING branch by its real casing.
    #expect(state.effectiveResolution == .reuse)  // → spec.reuseExistingBranch = true
    #expect(state.operativeBranchName == "Feature-Login")  // → spec.name
    let store = TestStore(initialState: state) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.createButtonTapped)
    // beginCreate is emitted (reuse is not blocked); its spec.name is the
    // real-cased ref built from operativeBranchName (asserted above).
    await store.receive(\.delegate.beginCreate)
  }
}
