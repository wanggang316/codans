import CodansCore
import ComposableArchitecture
import Foundation

/// Three-way collision classification for a branch-name draft, keyed on
/// the SANITIZED (directory-safe) lowercased form.  This is the single
/// source of truth consumed by the resolution UI and by `createButtonTapped`.
enum BranchCollisionKind: Equatable {
  /// No local collision — fresh create. Remote-only names also land here
  /// because classification keys on the LOCAL sets only.
  case none
  /// Branch exists as a local ref but no worktree currently checks it out.
  /// Re-creating will reuse the branch (commits kept, base ref ignored).
  case dangling
  /// Branch is checked out by a live worktree.
  /// Git refuses a second simultaneous checkout.
  case checkedOut
}

/// Identifies the (branch, base) pair a recreate unique-commit count was
/// requested for. Carried through the async effect so a result that lands
/// after the user has already retyped the branch or repicked the base is
/// recognised as STALE and dropped, rather than being applied to the new
/// selection (guard (a): a stale count must never carry across an edit).
struct RecreateGuardToken: Equatable, Sendable {
  let branch: String
  let base: String
}

/// Reducer backing the "+ Create Worktree" sheet. State tracks user
/// input, three-way option loading (branch refs / local branches /
/// default remote branch), live branch-name validation, and the
/// post-validation hand-off to the parent sidebar reducer.
///
/// After the pending-row redesign (worktree-sidebar-ordering.md
/// §pending 段), the streaming `wt sw` consumer + catalog write +
/// setup-script dispatch live on `HierarchySidebarFeature`. This
/// reducer's responsibility ends at `delegate(.beginCreate(pending))`.
@Reducer
struct CreateWorktreeFeature {
  /// Shared user-facing copy for the per-project pending cap (8). Used
  /// by both the sheet banner and the reducer's submitError so the two
  /// surfaces never drift.
  static let capMessage =
    "Up to 8 worktree creations are queued for this project. Wait for one to finish."

  @ObservableState
  struct State: Equatable {
    let projectID: ProjectID
    /// Git root of the Project. Used to run all `wt` / `git` commands
    /// and to derive the Worktree's on-disk path together with
    /// `worktreesDirectory`.
    let repoRoot: URL
    /// Base directory (spec "Worktree path derivation"). The sheet
    /// itself is read-only on this — changing it lives in the Project
    /// options flow owned by T-PROJECT.
    let worktreesDirectory: URL
    /// Snapshot of how many pending creations the parent sidebar already
    /// holds for this Project. Drives the cap banner + Create-button
    /// disable. Injected at sheet construction; the sheet does not read
    /// the parent's pending set.
    let currentPendingCountForProject: Int

    /// Per-Project Worktree base ref override (`projects[pid].git.worktreeBaseRef`).
    /// Wins over the auto-resolved `origin/HEAD` when seeding `selectedBaseRef`,
    /// so the value the user pinned in Project Settings actually drives new
    /// worktrees instead of being silently ignored. Implicit `nil` default keeps
    /// the synthesized memberwise initializer's parameter optional.
    var baseRefOverride: String?
    /// Saved default from `WorktreeSettings.branchConflictResolution`. Seeded once
    /// at sheet-open time by the parent; never mutated by the inline picker
    /// (per-creation overrides live in `selectedResolution` only).
    var savedResolutionDefault: BranchConflictResolution = .rename
    /// In-flight, per-creation resolution choice. Reset to `savedResolutionDefault`
    /// clamped to what is viable whenever `branchDraftChanged` reclassifies the
    /// collision kind. The inline picker binds here; mutations do NOT write settings.json.
    var selectedResolution: BranchConflictResolution = .rename

    // Options loaded asynchronously on presentation.
    var baseRefOptions: [String] = []
    var localBranchNamesLower: Set<String> = []
    /// Lowercased branches currently checked out by a LIVE worktree.
    /// A name in this set is a hard conflict (git won't check the same
    /// branch out twice). A name in `localBranchNamesLower` but NOT here
    /// is a "dangling" branch — re-creating reuses it instead of failing.
    var liveWorktreeBranchesLower: Set<String> = []
    var automaticBaseRef: String?
    var loadingOptions: Bool = true

    // User input. Seeded from the effective settings (per-project override
    // chained to global default) so the sheet matches what Settings shows
    // for this Project instead of always starting at false (HAN-83).
    var branchNameDraft: String = ""
    var selectedBaseRef: String?
    var fetchOrigin: Bool = true
    var copyIgnored: Bool = false
    var copyUntracked: Bool = false

    // Transient derived state.
    var validationError: String?
    var submitError: String?
    /// Collision kind for the current `branchNameDraft`, computed at
    /// keystroke time from the SANITIZED lowercased name.  The single
    /// source of truth consumed by the resolution UI and `createButtonTapped`.
    var branchCollisionKind: BranchCollisionKind = .none
    /// True while `validationError` is currently owned by the rename gate
    /// (effective `.rename` + a real collision). Lets `applyRenameGate` clear
    /// ONLY its own message without parsing message text, so a future
    /// non-gate validation message (M2 Recreate warning, empty-name, spaces,
    /// folder-exists, "Pick a base ref") is never clobbered by the gate.
    var renameGateActive: Bool = false

    // MARK: - Recreate guard (M2)

    /// Count of commits reachable from the dangling branch but NOT from the
    /// selected base — the commits a Recreate would permanently discard
    /// (`git rev-list --count <base>..<branch>`). Three-valued semantics:
    /// - `nil` while the count is being (re)computed OR after the compute
    ///   THREW (bad base / git error). `nil` is the FAIL-SAFE state: it is
    ///   NEVER treated as "0 unique commits" — the recreate stays gated
    ///   behind an explicit confirm. Coercing a throw to 0 would silently
    ///   bypass the guard, so we deliberately keep it `nil`.
    /// - `0` → the branch is fully merged into base; discarding it loses
    ///   nothing, so Recreate proceeds silently (no confirm control).
    /// - `> 0` → discarding drops N unique commits; a red warning + a
    ///   discrete confirm are required before Create is enabled.
    var recreateUniqueCount: Int?
    /// Set to `true` only after the compute THREW, so the UI can distinguish
    /// "still computing" (`recreateUniqueCount == nil`, `recreateCountFailed
    /// == false`) from "compute failed → treat as dangerous" (`nil` + `true`)
    /// and show a fail-safe warning naming the unknown-count risk.
    var recreateCountFailed: Bool = false
    /// Per-attempt acknowledgment for a Recreate that would discard commits
    /// (or whose count is unknown). Bound by a discrete Toggle in the sheet.
    /// Reset to `false` on ANY branch/base edit so a stale confirm can never
    /// carry onto a different branch or base (guard (a)).
    var recreateConfirmed: Bool = false

    // MARK: - Derived

    /// `selectedResolution` clamped to what is viable for `branchCollisionKind`:
    /// - `.none`      → `.rename` (fresh create; resolution is irrelevant).
    /// - `.dangling`  → `selectedResolution` unchanged (all three are valid).
    /// - `.checkedOut`→ forced `.rename` (git forbids a second checkout of the
    ///   same branch and refuses `branch -D` on a checked-out branch, so neither
    ///   Reuse nor Recreate can be executed).
    var effectiveResolution: BranchConflictResolution {
      switch branchCollisionKind {
      case .none: return .rename
      case .dangling: return selectedResolution
      case .checkedOut: return .rename
      }
    }

    /// Sanitized form of `branchNameDraft` (trim + sanitize), matching the
    /// directory name that `wt sw` will produce. Used by the checked-out
    /// explanatory message in the inline resolution control.
    var sanitizedBranchDraft: String {
      GitWorktreeClient.sanitizeBranchName(
        branchNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }

    /// True when the current form is a destructive Recreate of a dangling
    /// branch — the only context in which the unique-commit guard applies.
    /// `.none` (fresh create) and `.checkedOut` (forced to `.rename`) never
    /// reach here, so the guard is inert for them.
    var isRecreateContext: Bool {
      branchCollisionKind == .dangling && effectiveResolution == .recreate
    }

    /// True when a Recreate must be explicitly confirmed before Create is
    /// enabled — i.e. it would (or MIGHT) discard commits. This is the
    /// fail-safe gate: it is satisfied ONLY by a proven `0` count. A pending
    /// (`nil`, still computing), a FAILED (`nil`, threw), or a `> 0` count all
    /// require confirmation. Because `nil` is never coerced to `0`, an unknown
    /// count can never silently pass (guard (c)).
    var recreateNeedsConfirm: Bool {
      isRecreateContext && recreateUniqueCount != 0
    }

    /// Red warning copy for the recreate guard, or `nil` when no warning is
    /// shown (not a recreate context, or a proven-safe 0-count). Names the
    /// N commits that will be permanently deleted for the `> 0` case, and
    /// surfaces the fail-safe "couldn't determine" message when the count
    /// compute threw.
    var recreateWarning: String? {
      guard isRecreateContext else { return nil }
      let name = sanitizedBranchDraft
      if recreateCountFailed {
        return
          "Couldn't determine how many commits recreating \"\(name)\" would delete. "
          + "It will be force-deleted and recreated — confirm you want to discard it."
      }
      switch recreateUniqueCount {
      case .some(0), .none:
        // 0 → silent (no warning). nil while still computing → no warning yet;
        // the pending state simply keeps Create disabled via recreateNeedsConfirm.
        return nil
      case .some(let count):
        let plural = count == 1 ? "commit" : "commits"
        return
          "Recreating \"\(name)\" will permanently delete \(count) \(plural) "
          + "that exist only on this branch."
      }
    }

    /// Whether the Create button should be disabled for the recreate guard.
    /// Mirrors `recreateNeedsConfirm && !recreateConfirmed`; the reducer's
    /// submit path enforces the same predicate so a directly-dispatched
    /// `createButtonTapped` cannot bypass the disabled button.
    var recreateBlocksCreate: Bool {
      recreateNeedsConfirm && !recreateConfirmed
    }

    /// The (branch, base) token to compute the recreate unique-commit count
    /// for, or `nil` when the current form is not a recreate of a dangling
    /// branch with a selected base. Used both to launch the async count and
    /// to validate that a returning result still matches the live selection.
    var recreateGuardToken: RecreateGuardToken? {
      guard isRecreateContext else { return nil }
      let branch = sanitizedBranchDraft
      guard !branch.isEmpty, let base = selectedBaseRef, !base.isEmpty else {
        return nil
      }
      return RecreateGuardToken(branch: branch, base: base)
    }
  }

  enum Action: Equatable {
    case onAppear
    case optionsLoaded(
      baseRefs: [String],
      localBranchNamesLower: Set<String>,
      liveWorktreeBranchesLower: Set<String>,
      automaticBaseRef: String?
    )
    case branchDraftChanged(String)
    case validated(String?)
    case baseRefSelected(String?)
    case fetchOriginToggled(Bool)
    case copyIgnoredToggled(Bool)
    case copyUntrackedToggled(Bool)
    /// Inline picker changed the per-creation resolution. Does NOT write settings.json;
    /// the saved default is unaffected. The next sheet open re-seeds from the saved default.
    case resolutionChanged(BranchConflictResolution)
    /// Discrete confirm control for a destructive Recreate (guard). Bound by
    /// the sheet's Toggle; reset to `false` on any branch/base edit.
    case recreateConfirmedToggled(Bool)
    /// `branchUniqueCommitCount` resolved for the current recreate context.
    /// The `token` pins the (branch, base) the count was requested for so a
    /// stale in-flight result from a prior branch/base can be dropped instead
    /// of being applied to the current selection.
    case recreateCountLoaded(count: Int, token: RecreateGuardToken)
    /// `branchUniqueCommitCount` THREW for the current recreate context — the
    /// count is unknown. Handled fail-safe: never coerced to 0; forces the
    /// confirm-required path via `recreateCountFailed`.
    case recreateCountFailed(token: RecreateGuardToken)

    case createButtonTapped
    /// The submit-time `deleteBranchIfExists` refused (`.kept`) or otherwise
    /// could not delete the branch — abort with no `beginCreate` (guard (e)).
    case recreateDeleteFailed(String)

    case cancelButtonTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case dismissed
      /// Form is valid and pre-checks passed. Parent dismisses the
      /// sheet and starts the pending lifecycle.
      case beginCreate(PendingWorktree)
    }
  }

  @Dependency(GitWorktreeClient.self) private var gitWorktreeClient

  // MARK: - Rename gate helper

  /// Re-evaluates the rename-collision gate whenever classification or the
  /// inline resolution selection changes.  Sets `validationError` when the
  /// **effective** resolution is `.rename` and there is a real collision;
  /// clears it when the collision resolves or the user switches away from
  /// Rename (e.g. to Reuse).
  ///
  /// Ownership is tracked in `renameGateActive` (not by parsing the message
  /// text): the clear branch touches `validationError` ONLY when the gate set
  /// it, so a non-gate message (empty-name, spaces, folder-exists, "Pick a
  /// base ref", or M2's Recreate warning) is never clobbered.
  ///
  /// Call this AFTER `branchCollisionKind` and `selectedResolution` are both
  /// up-to-date so `effectiveResolution` reflects the new state.
  private static func applyRenameGate(to state: inout State) {
    let shouldGate =
      state.branchCollisionKind != .none && state.effectiveResolution == .rename
    if shouldGate {
      // Effective rename + collision → block Create until the name is free.
      let name = state.sanitizedBranchDraft
      state.validationError =
        "Branch \"\(name)\" already exists — choose a different name."
      state.renameGateActive = true
    } else if state.renameGateActive {
      // Collision resolved OR user switched off Rename → retract our own
      // message only. Guarding on renameGateActive means we never clear a
      // message some other validation path currently owns.
      state.validationError = nil
      state.renameGateActive = false
    }
  }

  // MARK: - Recreate guard helper

  /// Re-evaluates the destructive-Recreate guard after ANY change that can
  /// alter the (branch, base, resolution) triple: `branchDraftChanged`,
  /// `baseRefSelected`, and `resolutionChanged`. Two jobs:
  ///
  /// 1. FAIL-SAFE RESET — always clears the prior count, the failed flag, and
  ///    the per-attempt confirm. Resetting `recreateConfirmed` here is the
  ///    load-bearing part of guard (a): a stale confirm from a previous branch
  ///    or base can NEVER survive an edit. Resetting to `nil` (not `0`) keeps
  ///    Create disabled through the recompute window (guard (c)).
  /// 2. RECOMPUTE — when the new form is a recreate of a dangling branch with
  ///    a selected base, returns the async effect that runs
  ///    `branchUniqueCommitCount`. Otherwise returns `.none`.
  ///
  /// The returned effect is tagged with `RecreateGuardToken` so a result that
  /// lands after another edit is dropped as stale by the reducer.
  private func refreshRecreateGuard(to state: inout State) -> Effect<Action> {
    // Always start from a clean, gated slate.
    state.recreateUniqueCount = nil
    state.recreateCountFailed = false
    state.recreateConfirmed = false

    guard let token = state.recreateGuardToken else {
      // Not a recreate-of-dangling context (or no base yet) → nothing to
      // compute; the reset above already cleared any prior guard state.
      return .none
    }

    let repoRoot = state.repoRoot
    let client = gitWorktreeClient
    return .run { send in
      do {
        let count = try await client.branchUniqueCommitCount(
          repoRoot, token.branch, token.base
        )
        await send(.recreateCountLoaded(count: count, token: token))
      } catch {
        // NEVER coerce a throw to 0 — surface the failure so the reducer
        // forces the confirm-required path (guard (c)).
        await send(.recreateCountFailed(token: token))
      }
    }
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        state.loadingOptions = true
        let repoRoot = state.repoRoot
        let client = gitWorktreeClient
        return .run { send in
          async let refs = (try? client.branchRefs(repoRoot)) ?? []
          async let locals =
            (try? client.localBranchNames(repoRoot)) ?? []
          async let live = (try? client.lsWorktrees(repoRoot)) ?? []
          async let auto = (try? client.defaultRemoteBranchRef(repoRoot)) ?? nil
          let loadedRefs = await refs
          let loadedLocals = await locals
          let loadedLive = Set(
            await live
              .map { $0.branch.trimmingCharacters(in: .whitespaces).lowercased() }
              .filter { !$0.isEmpty }
          )
          let loadedAuto = await auto
          await send(
            .optionsLoaded(
              baseRefs: loadedRefs,
              localBranchNamesLower: loadedLocals,
              liveWorktreeBranchesLower: loadedLive,
              automaticBaseRef: loadedAuto
            ))
        }

      case .optionsLoaded(let baseRefs, let locals, let live, let auto):
        state.loadingOptions = false
        state.baseRefOptions = baseRefs
        state.localBranchNamesLower = locals
        state.liveWorktreeBranchesLower = live
        state.automaticBaseRef = auto
        // Preserve a user-set value if they already picked one while
        // options were loading. Otherwise prefer the per-Project override
        // (only if it still exists in the loaded ref list), then fall back
        // to the remote default, then the first available ref.
        if state.selectedBaseRef == nil {
          if let pinned = state.baseRefOverride, baseRefs.contains(pinned) {
            state.selectedBaseRef = pinned
          } else {
            state.selectedBaseRef = auto ?? baseRefs.first
          }
        }
        return .none

      case .branchDraftChanged(let draft):
        state.branchNameDraft = draft
        // Live-validate synchronously against the branch sets we already
        // fetched. The `git check-ref-format` path is also exercised on
        // Create — no need to shell out on every keystroke.
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          state.branchCollisionKind = .none
          state.validationError = nil
          state.renameGateActive = false
          state.selectedResolution = state.savedResolutionDefault
        } else if trimmed.contains(where: \.isWhitespace) {
          state.branchCollisionKind = .none
          state.validationError = "Branch names can't contain spaces."
          // This branch owns validationError directly; drop any gate ownership
          // so a later clear can't retract this space message.
          state.renameGateActive = false
          state.selectedResolution = state.savedResolutionDefault
        } else {
          // Clear any prior validation error before reclassifying — the
          // correct error (if any) will be re-set by applyRenameGate below.
          // Also drop stale gate ownership; applyRenameGate re-arms it.
          state.validationError = nil
          state.renameGateActive = false
          // Classify on the SANITIZED, lowercased name — identical to the
          // form that git-wt will actually create — so a name that only
          // collides after sanitization (doubled separators, trailing dashes,
          // etc.) is flagged WHILE TYPING, not just on Create.
          let sanitized = GitWorktreeClient.sanitizeBranchName(trimmed)
          let lower = sanitized.lowercased()
          if state.liveWorktreeBranchesLower.contains(lower) {
            // Checked out by a live worktree — git refuses a second checkout
            // and forbids `branch -D` on a checked-out branch. Neither Reuse
            // nor Recreate is viable; force Rename. The rename gate (below)
            // then blocks Create until the user picks a free name.
            state.branchCollisionKind = .checkedOut
            state.selectedResolution = .rename
          } else if state.localBranchNamesLower.contains(lower) {
            // Dangling branch: exists as a local ref but no worktree checks it
            // out. All three resolutions are valid — seed to the saved default.
            state.branchCollisionKind = .dangling
            state.selectedResolution = state.savedResolutionDefault
          } else {
            // Remote-only names (e.g. origin/foo with no local foo) also
            // land here: classification keys on LOCAL sets only.
            state.branchCollisionKind = .none
            state.selectedResolution = state.savedResolutionDefault
          }
          // Reactive rename gate: set/clear validationError based on the
          // now-current (branchCollisionKind, effectiveResolution) pair.
          Self.applyRenameGate(to: &state)
        }
        // Recreate guard (a): every draft edit resets the per-attempt confirm
        // and recomputes the unique-commit count for the new (branch, base).
        // A stale confirm from a previous name can never carry over.
        return refreshRecreateGuard(to: &state)

      case .validated(let error):
        state.validationError = error
        return .none

      case .baseRefSelected(let ref):
        state.selectedBaseRef = ref
        // Recreate guards (a)+(b): a base change resets the confirm and
        // re-evaluates the count, so silent(0) ⇄ warn(>0) flips both ways
        // and a confirm never survives a base swap.
        return refreshRecreateGuard(to: &state)

      case .fetchOriginToggled(let value):
        state.fetchOrigin = value
        return .none

      case .copyIgnoredToggled(let value):
        state.copyIgnored = value
        return .none

      case .copyUntrackedToggled(let value):
        state.copyUntracked = value
        return .none

      case .resolutionChanged(let resolution):
        // Per-creation inline override only — no settings write.
        state.selectedResolution = resolution
        // Reactive rename gate: switching to/from Rename while a collision
        // exists toggles the Create block.
        Self.applyRenameGate(to: &state)
        // Recreate guard: entering `.recreate` on a dangling branch kicks off
        // the unique-commit count; leaving it clears the guard. Also resets
        // the per-attempt confirm so toggling resolutions can't reuse a stale
        // acknowledgment.
        return refreshRecreateGuard(to: &state)

      case .recreateConfirmedToggled(let value):
        state.recreateConfirmed = value
        return .none

      case .recreateCountLoaded(let count, let token):
        // Drop a stale result: if the user retyped the branch or repicked the
        // base while this count was in flight, the live token no longer
        // matches and applying `count` would poison the guard for the NEW
        // selection. Ignoring it leaves the guard `nil` (still confirm-gated)
        // until the recompute for the current token lands.
        guard state.recreateGuardToken == token else { return .none }
        state.recreateUniqueCount = count
        state.recreateCountFailed = false
        return .none

      case .recreateCountFailed(let token):
        guard state.recreateGuardToken == token else { return .none }
        // Fail-safe: keep the count unknown (`nil`, never 0) and flag the
        // failure so the guard forces the confirm-required path (guard (c)).
        state.recreateUniqueCount = nil
        state.recreateCountFailed = true
        return .none

      case .createButtonTapped:
        let trimmed = state.branchNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state.validationError == nil else {
          state.validationError = state.validationError ?? "Branch name required."
          return .none
        }
        guard let baseRef = state.selectedBaseRef, !baseRef.isEmpty else {
          state.validationError = "Pick a base ref."
          return .none
        }
        let directoryName = GitWorktreeClient.sanitizeBranchName(trimmed)
        guard !directoryName.isEmpty else {
          state.validationError = "Branch name produces an empty directory name."
          return .none
        }
        // Drive the spec flag from the effective resolution (selectedResolution
        // clamped to viable).  By the time we reach here the rename gate in
        // `applyRenameGate` has already ensured that if effectiveResolution is
        // `.rename` AND there is a collision, `validationError` is set and the
        // guard above has returned early.  So `.reuse` is the only path that
        // sets `reuseExistingBranch = true`; all other cases (including fresh
        // `.none` creates) leave it false — making git the final arbiter on
        // a race (VAL-CROSS-003).
        let reuseExistingBranch = state.effectiveResolution == .reuse
        // Branch names like `feature/abc` map to nested folders
        // (`feature/abc`); `appending(path:)` honours the embedded
        // separator, whereas `appending(component:)` would percent-encode
        // the slash and break the diff against `wt ls --json` (HAN-57).
        let targetURL = state.worktreesDirectory
          .appending(path: directoryName)
        if FileManager.default.fileExists(atPath: targetURL.path(percentEncoded: false)) {
          state.submitError = """
            A folder named \"\(directoryName)\" already exists at the Project's \
            worktrees directory. Choose a different branch name.
            """
          return .none
        }
        guard state.currentPendingCountForProject < 8 else {
          state.submitError = Self.capMessage
          return .none
        }

        // Recreate confirm re-guard (guard (d)): a destructive Recreate that
        // still needs confirmation must NOT proceed when dispatched directly
        // (the button is disabled in the UI, but the reducer is the source of
        // truth). No delete, no beginCreate — a strict no-op beyond surfacing
        // the reason. `recreateBlocksCreate` is false for a proven 0-count
        // (silent) and for a checked-in confirm, so both proceed below.
        if state.recreateBlocksCreate {
          state.submitError =
            "Confirm that recreating this branch will discard its commits before continuing."
          return .none
        }

        state.submitError = nil

        let spec = CreateWorktreeSpec(
          repoRoot: state.repoRoot,
          baseDirectory: state.worktreesDirectory,
          name: directoryName,
          baseRef: baseRef,
          fetchOrigin: state.fetchOrigin,
          copyIgnored: state.copyIgnored,
          copyUntracked: state.copyUntracked,
          reuseExistingBranch: reuseExistingBranch
        )
        let pending = PendingWorktree(
          id: PendingWorktreeID(),
          projectID: state.projectID,
          spec: spec,
          displayName: trimmed,
          status: .running,
          lastProgressLine: nil,
          startedAt: Date()
        )

        // Non-recreate paths (fresh create, rename, reuse) hand straight to
        // the parent's pending lifecycle. Only the destructive Recreate path
        // must delete the dangling branch FIRST, sequenced before beginCreate.
        guard state.effectiveResolution == .recreate else {
          return .send(.delegate(.beginCreate(pending)))
        }

        // Recreate execution: force-delete the same-name (dangling) branch,
        // THEN emit a FRESH create (`reuseExistingBranch` is already false, so
        // the spec carries `-b` from the selected base). The delete is the
        // submit-time re-guard for guard (e): if the branch became checked out
        // since selection, `deleteBranchIfExists` returns `.kept` and we abort
        // with the reason surfaced and NO beginCreate — nothing is created and
        // the branch is left intact. `git branch -D` keeps the discarded tip
        // reflog-recoverable, so no extra recovery code is needed.
        let repoRoot = state.repoRoot
        let branch = directoryName
        let client = gitWorktreeClient
        return .run { send in
          let outcome = await client.deleteBranchIfExists(repoRoot, branch)
          switch outcome {
          case .deleted, .absent:
            await send(.delegate(.beginCreate(pending)))
          case .kept(let reason):
            await send(.recreateDeleteFailed(reason))
          }
        }

      case .recreateDeleteFailed(let reason):
        // The branch could not be deleted (checked out since selection, or a
        // git refusal). Surface why and emit NO beginCreate — no half state:
        // the branch, its commits, and any directory are untouched.
        state.submitError =
          "Couldn't recreate the branch — it wasn't deleted, so nothing was created. \(reason)"
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.dismissed))

      case .delegate:
        return .none
      }
    }
  }
}
