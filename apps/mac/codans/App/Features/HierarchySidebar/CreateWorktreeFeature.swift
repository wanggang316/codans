import ComposableArchitecture
import Foundation
import CodansCore

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

    case createButtonTapped

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
        return .none

      case .validated(let error):
        state.validationError = error
        return .none

      case .baseRefSelected(let ref):
        state.selectedBaseRef = ref
        return .none

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
        return .send(.delegate(.beginCreate(pending)))

      case .cancelButtonTapped:
        return .send(.delegate(.dismissed))

      case .delegate:
        return .none
      }
    }
  }
}
