import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// Synchronous-branch coverage for `CreateWorktreeFeature`. The async
/// option-load and streaming-create paths are exercised end-to-end by
/// the M13 integration test against a real temp repo; here we lock the
/// live-validator branches, the collision classification + note
/// metadata, the collision Create-block, and the cancel delegate —
/// the branches a future refactor is most likely to silently break.
@MainActor
struct CreateWorktreeFeatureTests {
  private func initialState(
    currentPendingCountForProject: Int = 0,
    localBranchNames: Set<String> = ["main", "feature/existing"]
  ) -> CreateWorktreeFeature.State {
    var state = CreateWorktreeFeature.State(
      projectID: ProjectID(),
      repoRoot: URL(fileURLWithPath: "/tmp/repo"),
      worktreesDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      currentPendingCountForProject: currentPendingCountForProject
    )
    // Derive both classification structures from one original-cased source —
    // exactly as the reducer does on `.optionsLoaded` — so the lowercased match
    // set and the [lowercased: original] casing-recovery map stay in sync.
    // "main" is checked out by the main worktree (live conflict);
    // "feature/existing" exists as a ref but has no worktree (dangling).
    CreateWorktreeFeature.ingestLocalBranchNames(localBranchNames, into: &state)
    state.liveWorktreeOwnersByLower = [
      "main": LiveBranchOwner(branch: "main", worktreeName: "repo")
    ]
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

  // MARK: - branchCollisionKind classification + note metadata

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

  /// A live-branch collision resolves the OWNER (real-cased branch + the
  /// holding worktree's name) so the conflict note can state the reason.
  @Test
  func branchCollisionKindCheckedOutResolvesOwner() async {
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("main")) {
      $0.branchNameDraft = "main"
      $0.branchCollisionKind = .checkedOut
      $0.checkedOutOwner = LiveBranchOwner(branch: "main", worktreeName: "repo")
      $0.danglingRealName = nil
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
      $0.danglingRealName = "feature/existing"
      $0.checkedOutOwner = nil
    }
  }

  @Test
  func branchCollisionKindDoubleSeparatorNormalizesToDangling() async {
    // "feature//existing" raw ≠ "feature/existing" in the set, but after
    // sanitizeBranchName the doubled slash collapses → "feature/existing"
    // which IS in localBranchNamesLower. Old raw-compare would show .none;
    // the sanitized classification flags it while typing.
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("feature//existing")) {
      $0.branchCollisionKind = .dangling
      $0.danglingRealName = "feature/existing"
    }
  }

  @Test
  func branchCollisionKindCaseFoldAndSeparatorNormalizesToCheckedOut() async {
    // "MAIN" (uppercase) sanitizes to "MAIN", then lowercased → "main" which
    // is in the live-owner map. Verifies the case-fold path in the
    // sanitized classification.
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("MAIN")) {
      $0.branchCollisionKind = .checkedOut
      $0.checkedOutOwner = LiveBranchOwner(branch: "main", worktreeName: "repo")
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

  /// Existing local ref is mixed-case; the user types the all-lowercase
  /// form. The match is case-insensitive and the note metadata resolves to
  /// the REAL casing so the user's cleanup targets the actual ref.
  @Test
  func caseMismatchResolvesDanglingRealNameToExistingRef() async {
    let store = TestStore(
      initialState: initialState(localBranchNames: ["main", "Feature-Login"])
    ) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("feature-login")) {
      $0.branchNameDraft = "feature-login"
      $0.branchCollisionKind = .dangling
      $0.danglingRealName = "Feature-Login"
    }
  }

  /// Leaving a collision (typing on to a free name) clears BOTH note
  /// metadata fields so a stale owner / real name can never label the
  /// wrong draft.
  @Test
  func leavingCollisionClearsNoteMetadata() async {
    let store = TestStore(initialState: initialState()) {
      CreateWorktreeFeature()
    }
    store.exhaustivity = .off
    await store.send(.branchDraftChanged("main")) {
      $0.branchCollisionKind = .checkedOut
      $0.checkedOutOwner = LiveBranchOwner(branch: "main", worktreeName: "repo")
    }
    await store.send(.branchDraftChanged("main-two")) {
      $0.branchNameDraft = "main-two"
      $0.branchCollisionKind = .none
      $0.checkedOutOwner = nil
      $0.danglingRealName = nil
    }
  }

  // MARK: - Create gating

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

  /// Collisions are informational-only in the sheet, but the reducer stays
  /// the source of truth: a directly-dispatched Create on a colliding name
  /// (the button is disabled in the UI) emits NO beginCreate and surfaces
  /// why — for BOTH collision kinds.
  @Test
  func collisionBlocksDirectlyDispatchedCreate() async {
    for (draft, expectedName) in [("main", "main"), ("feature/existing", "feature/existing")] {
      var state = initialState()
      state.selectedBaseRef = "origin/main"
      let store = TestStore(initialState: state) {
        CreateWorktreeFeature()
      }
      store.exhaustivity = .off
      await store.send(.branchDraftChanged(draft))
      await store.send(.createButtonTapped) {
        $0.submitError =
          "\"\(expectedName)\" conflicts with an existing branch — see the note above."
      }
      // No beginCreate in flight: finish() would surface an unasserted
      // delegate receive if the guard leaked one.
      await store.finish()
    }
  }
}
