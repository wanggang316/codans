import CodansCore
import ComposableArchitecture
import Foundation

/// Three-way collision classification for a branch-name draft, keyed on
/// the SANITIZED (directory-safe) lowercased form. This is the single
/// source of truth consumed by the sheet's conflict note, the Create
/// button's disable predicate, and `createButtonTapped`'s guard.
///
/// A collision is informational-only: the sheet explains WHY the name is
/// taken and Create stays disabled until the user resolves it themselves
/// (pick a different name, or clean up / switch to the existing branch
/// outside the sheet). There is no in-app resolution machinery.
enum BranchCollisionKind: Equatable {
  /// No local collision — fresh create. Remote-only names also land here
  /// because classification keys on the LOCAL sets only.
  case none
  /// Branch exists as a local ref but no worktree currently checks it out —
  /// typically left behind when a worktree was removed but its branch kept.
  case dangling
  /// Branch is checked out by a live worktree.
  /// Git refuses a second simultaneous checkout.
  case checkedOut
  /// Branch belongs to an ARCHIVED worktree — invisible in the sidebar,
  /// but its git worktree/branch still exists behind the archived flag.
  /// Presented separately from `.checkedOut` because "checked out by a
  /// worktree you can't see" reads as a bug; the note points at the
  /// Archived Worktrees sheet instead.
  case archivedWorktree
}

/// A live worktree's claim on a branch: the branch's REAL casing plus the
/// owning worktree's display name (its directory name). Carried into the
/// checked-out conflict note so it can say WHO holds the name — the reason
/// the collision exists.
struct LiveBranchOwner: Equatable, Sendable {
  let branch: String
  let worktreeName: String
}

/// Reducer backing the "+ Create Worktree" sheet. State tracks user
/// input, three-way option loading (branch refs / local branches /
/// default remote branch), live branch-name validation, and the
/// post-validation hand-off to the parent sidebar reducer.
///
/// The streaming `wt sw` consumer + catalog write + setup-script dispatch
/// live on `HierarchySidebarFeature`. This reducer's responsibility ends
/// at `delegate(.beginCreate(pending))`.
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
    /// Base directory for deriving the Worktree's on-disk path. The sheet
    /// itself is read-only on this — changing it lives in the Project
    /// options flow.
    let worktreesDirectory: URL
    /// Snapshot of how many pending creations the parent sidebar already
    /// holds for this Project. Drives the cap banner + Create-button
    /// disable. Injected at sheet construction; the sheet does not read
    /// the parent's pending set.
    let currentPendingCountForProject: Int

    /// Server (remote) project's SSH host, `nil` for local. When set,
    /// `repoRoot` / `worktreesDirectory` are remote path strings, option
    /// loading rides the SSH-routed client, and the wt-only toggles (copy
    /// ignored / untracked) are hidden — creation runs plain `git worktree
    /// add` on the host. Local-filesystem probes (the target-folder existence
    /// check) are skipped; git's own "already exists" error covers the
    /// collision on the host side. Stamped onto the `PendingWorktree` so the
    /// run needs no catalog lookup.
    var remoteHost: RemoteHost?

    var isRemote: Bool { remoteHost != nil }

    /// Per-Project Worktree base ref override (`projects[pid].git.worktreeBaseRef`).
    /// Wins over the auto-resolved `origin/HEAD` when seeding `selectedBaseRef`,
    /// so the value the user pinned in Project Settings actually drives new
    /// worktrees instead of being silently ignored. Implicit `nil` default keeps
    /// the synthesized memberwise initializer's parameter optional.
    var baseRefOverride: String?

    // Options loaded asynchronously on presentation.
    var baseRefOptions: [String] = []
    var localBranchNamesLower: Set<String> = []
    /// ORIGINAL-cased local branch names (as `git for-each-ref` reports them),
    /// keyed by their lowercased form. Classification matches case-INSENSITIVELY
    /// via `localBranchNamesLower`, but the conflict note must name the matched
    /// ref's REAL casing — the draft's casing may differ from the existing ref,
    /// and the user acts (deletes / inspects) on the branch git actually has.
    /// `branchDraftChanged` reads this to recover the exact ref for
    /// `danglingRealName`.
    var localBranchNamesByLower: [String: String] = [:]
    /// Branches currently checked out by a LIVE worktree, keyed by their
    /// lowercased form. The value carries the branch's real casing and the
    /// owning worktree's display name so the conflict note can say WHO holds
    /// the name. A name in this map is a hard conflict (git won't check the
    /// same branch out twice); a name in `localBranchNamesLower` but NOT here
    /// is a "dangling" branch.
    var liveWorktreeOwnersByLower: [String: LiveBranchOwner] = [:]
    /// Branches held by the project's ARCHIVED worktrees, keyed by their
    /// lowercased form. Seeded at sheet CONSTRUCTION from the catalog (the
    /// parent sidebar owns that knowledge; git alone can't tell archived
    /// from live — the git worktree still exists). Classification checks
    /// this FIRST so a collision with an invisible row is explained as
    /// "archived", not as a checkout the user can't find.
    var archivedBranchOwnersByLower: [String: LiveBranchOwner] = [:]
    var automaticBaseRef: String?
    var loadingOptions: Bool = true

    // User input. Seeded from the effective settings (per-project override
    // chained to global default) so the sheet matches what Settings shows
    // for this Project instead of always starting at false.
    var branchNameDraft: String = ""
    var selectedBaseRef: String?
    var fetchOrigin: Bool = true
    var copyIgnored: Bool = false
    var copyUntracked: Bool = false

    // Transient derived state.
    var validationError: String?
    var submitError: String?
    /// Collision kind for the current `branchNameDraft`, computed at
    /// keystroke time from the SANITIZED lowercased name. The single
    /// source of truth consumed by the conflict note, the Create button's
    /// disable predicate, and `createButtonTapped`.
    var branchCollisionKind: BranchCollisionKind = .none
    /// The REAL-cased name of the matched dangling ref, resolved at
    /// classification time from `localBranchNamesByLower`. `nil` when the
    /// draft is not on a dangling collision. The conflict note names this
    /// (not the draft's casing) so the user's cleanup targets the branch
    /// git actually has.
    var danglingRealName: String?
    /// The live worktree holding the drafted name, resolved at
    /// classification time from `liveWorktreeOwnersByLower`. `nil` when the
    /// draft is not on a checked-out collision. The conflict note names it
    /// as the reason the branch is unavailable.
    var checkedOutOwner: LiveBranchOwner?
    /// The ARCHIVED worktree holding the drafted name, resolved at
    /// classification time from `archivedBranchOwnersByLower`. `nil` when
    /// the draft is not on an archived collision. The conflict note names
    /// it and points at the Archived Worktrees sheet.
    var archivedOwner: LiveBranchOwner?

    // MARK: - Derived

    /// Sanitized form of `branchNameDraft` (trim + sanitize), matching the
    /// directory name that `wt sw` will produce. Used by the conflict note
    /// as the fallback display name when no real-cased ref was resolved.
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
      /// ORIGINAL-cased local branch names. The reducer derives both the
      /// lowercased match set and the `[lowercased: original]` map from this so
      /// the conflict note can recover a matched ref's exact casing.
      localBranchNames: Set<String>,
      liveWorktreeOwners: [String: LiveBranchOwner],
      automaticBaseRef: String?
    )
    case branchDraftChanged(String)
    case validated(String?)
    case baseRefSelected(String?)
    case fetchOriginToggled(Bool)
    case copyIgnoredToggled(Bool)
    case copyUntrackedToggled(Bool)

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

  // MARK: - Local-branch ingestion

  /// Derives the two collision-classification structures from a single
  /// ORIGINAL-cased set of local branch names:
  /// - `localBranchNamesLower` — the lowercased set used for the
  ///   case-INSENSITIVE collision match (a draft `feature-login` matches an
  ///   existing `Feature-Login`).
  /// - `localBranchNamesByLower` — a `[lowercased: original]` map so a matched
  ///   ref's EXACT casing can be recovered for the conflict note. On a
  ///   collision of two names differing only by case (unusual but legal on a
  ///   case-sensitive FS) the last one wins; either names a real ref.
  ///
  /// Keeping both derived from the same source in one place stops them from
  /// drifting apart.
  static func ingestLocalBranchNames(_ names: Set<String>, into state: inout State) {
    var lower = Set<String>()
    var byLower = [String: String]()
    for name in names {
      let key = name.lowercased()
      lower.insert(key)
      byLower[key] = name
    }
    state.localBranchNamesLower = lower
    state.localBranchNamesByLower = byLower
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
          // Original-cased local branch names — the reducer derives the
          // lowercased match set + the casing-recovery map from these.
          let loadedLocals = await locals
          // Live worktree claims: lowercased branch → (real casing, owning
          // worktree's directory name). The note uses the value to say WHO
          // holds a checked-out name. Two worktrees can never hold the same
          // branch (git forbids it), so key collisions don't occur in
          // practice; keep the first defensively.
          let loadedLive = Dictionary(
            await live.compactMap { entry -> (String, LiveBranchOwner)? in
              let branch = entry.branch.trimmingCharacters(in: .whitespaces)
              guard !branch.isEmpty else { return nil }
              return (
                branch.lowercased(),
                LiveBranchOwner(
                  branch: branch,
                  worktreeName: URL(fileURLWithPath: entry.path).lastPathComponent
                )
              )
            },
            uniquingKeysWith: { first, _ in first }
          )
          let loadedAuto = await auto
          await send(
            .optionsLoaded(
              baseRefs: loadedRefs,
              localBranchNames: loadedLocals,
              liveWorktreeOwners: loadedLive,
              automaticBaseRef: loadedAuto
            ))
        }

      case .optionsLoaded(let baseRefs, let locals, let live, let auto):
        state.loadingOptions = false
        state.baseRefOptions = baseRefs
        // Derive the lowercased MATCH set (classification is case-insensitive)
        // and the [lowercased: original] map (the note recovers the real
        // casing) from the single original-cased source, so the two never
        // drift.
        Self.ingestLocalBranchNames(locals, into: &state)
        state.liveWorktreeOwnersByLower = live
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
          state.danglingRealName = nil
          state.checkedOutOwner = nil
          state.archivedOwner = nil
          state.validationError = nil
        } else if trimmed.contains(where: \.isWhitespace) {
          state.branchCollisionKind = .none
          state.danglingRealName = nil
          state.checkedOutOwner = nil
          state.archivedOwner = nil
          state.validationError = "Branch names can't contain spaces."
        } else {
          state.validationError = nil
          // Classify on the SANITIZED, lowercased name — identical to the
          // form that git-wt will actually create — so a name that only
          // collides after sanitization (doubled separators, trailing dashes,
          // etc.) is flagged WHILE TYPING, not just on Create.
          let sanitized = GitWorktreeClient.sanitizeBranchName(trimmed)
          let lower = sanitized.lowercased()
          if let archived = state.archivedBranchOwnersByLower[lower] {
            // Held by an ARCHIVED worktree. Checked FIRST: the same branch
            // usually also appears in the live-git map (archiving keeps the
            // git worktree), but "checked out by a worktree you can't see
            // in the sidebar" would read as a bug — name the archived row
            // and point at the Archived Worktrees sheet instead.
            state.branchCollisionKind = .archivedWorktree
            state.archivedOwner = archived
            state.checkedOutOwner = nil
            state.danglingRealName = nil
          } else if let owner = state.liveWorktreeOwnersByLower[lower] {
            // Checked out by a live worktree — git refuses a second
            // checkout, so the name is simply unavailable. The note names
            // the owning worktree; Create stays disabled until the draft
            // stops colliding.
            state.branchCollisionKind = .checkedOut
            state.checkedOutOwner = owner
            state.danglingRealName = nil
            state.archivedOwner = nil
          } else if state.localBranchNamesLower.contains(lower) {
            // Dangling branch: exists as a local ref but no worktree checks
            // it out — usually left behind by a removed worktree. Recover
            // the EXACT existing ref casing (the draft may differ, e.g.
            // `feature-login` typed against an existing `Feature-Login`) so
            // the note tells the user which branch to act on. Fall back to
            // the sanitized draft only if the map somehow lacks the key
            // (race).
            state.branchCollisionKind = .dangling
            state.danglingRealName = state.localBranchNamesByLower[lower] ?? sanitized
            state.checkedOutOwner = nil
            state.archivedOwner = nil
          } else {
            // Remote-only names (e.g. origin/foo with no local foo) also
            // land here: classification keys on LOCAL sets only.
            state.branchCollisionKind = .none
            state.danglingRealName = nil
            state.checkedOutOwner = nil
            state.archivedOwner = nil
          }
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
        let sanitizedDraftName = GitWorktreeClient.sanitizeBranchName(trimmed)
        guard !sanitizedDraftName.isEmpty else {
          state.validationError = "Branch name produces an empty directory name."
          return .none
        }
        // Collisions are informational-only: the note under the name field
        // explains WHY the name is taken and the user resolves it outside
        // the sheet (different name, delete the leftover branch, or work in
        // the worktree that holds it). The Create button is disabled while
        // a collision exists; this reducer-side guard covers direct
        // dispatches — the reducer stays the source of truth.
        guard state.branchCollisionKind == .none else {
          state.submitError =
            "\"\(sanitizedDraftName)\" conflicts with an existing branch — see the note above."
          return .none
        }
        // Branch names like `feature/abc` map to nested folders
        // (`feature/abc`); `appending(path:)` honours the embedded
        // separator, whereas `appending(component:)` would percent-encode
        // the slash and break the diff against `wt ls --json`.
        let targetURL = state.worktreesDirectory
          .appending(path: sanitizedDraftName)
        // Local-only probe: a remote target can't be stat'd here — git's own
        // "already exists" failure surfaces the collision on the host instead.
        if !state.isRemote,
          FileManager.default.fileExists(atPath: targetURL.path(percentEncoded: false))
        {
          state.submitError = """
            A folder named \"\(sanitizedDraftName)\" already exists at the Project's \
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
          name: sanitizedDraftName,
          baseRef: baseRef,
          fetchOrigin: state.fetchOrigin,
          copyIgnored: state.copyIgnored,
          copyUntracked: state.copyUntracked
        )
        let pending = PendingWorktree(
          id: PendingWorktreeID(),
          projectID: state.projectID,
          remoteHost: state.remoteHost,
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
