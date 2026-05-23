import ComposableArchitecture
import Foundation
import TouchCodeCore

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

    // Options loaded asynchronously on presentation.
    var baseRefOptions: [String] = []
    var localBranchNamesLower: Set<String> = []
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
  }

  enum Action: Equatable {
    case onAppear
    case optionsLoaded(
      baseRefs: [String],
      localBranchNamesLower: Set<String>,
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
          async let auto = (try? client.defaultRemoteBranchRef(repoRoot)) ?? nil
          let loadedRefs = await refs
          let loadedLocals = await locals
          let loadedAuto = await auto
          await send(
            .optionsLoaded(
              baseRefs: loadedRefs,
              localBranchNamesLower: loadedLocals,
              automaticBaseRef: loadedAuto
            ))
        }

      case .optionsLoaded(let baseRefs, let locals, let auto):
        state.loadingOptions = false
        state.baseRefOptions = baseRefs
        state.localBranchNamesLower = locals
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
        // Live-validate synchronously against the local-branch set we
        // already fetched. The `git check-ref-format` path is also
        // exercised on Create — no need to shell out on every keystroke.
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          state.validationError = nil
        } else if trimmed.contains(where: \.isWhitespace) {
          state.validationError = "Branch names can't contain spaces."
        } else if state.localBranchNamesLower.contains(trimmed.lowercased()) {
          state.validationError = "Branch \"\(trimmed)\" already exists."
        } else {
          state.validationError = nil
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
        let directoryName = GitWorktreeClient.sanitizeBranchName(trimmed)
        guard !directoryName.isEmpty else {
          state.validationError = "Branch name produces an empty directory name."
          return .none
        }
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
          copyUntracked: state.copyUntracked
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
