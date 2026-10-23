import CodansCore
import Foundation

/// One project of a new named group in the New Group sheet: the options it
/// is checked out with, its branches for the base-ref menu, and its findings
/// and progress.
nonisolated struct WorkspaceGroupMemberDraft: Equatable, Identifiable, Sendable {
  enum Progress: Equatable, Sendable {
    case pending
    case running(WorkspaceCreationEvent.Phase, lastLine: String?)
    case done
    case failed(String)
    case rolledBack
    /// The setup command is running; every checkout exists.
    case settingUp(lastLine: String?)
    /// The setup command failed; the checkout stays.
    case setupFailed(String)
  }

  var options: MemberCreationOptions
  var refs: RefsState = .idle
  /// Findings from the client's preflight for this project.
  var preflightIssues: [WorkspacePreflight.Issue] = []
  var progress: Progress = .pending

  var id: String { options.id }
  var name: String { options.name }

  init(options: MemberCreationOptions) {
    self.options = options
  }
}

/// Branches a repository offers to a ref menu, as loaded for the sheet.
nonisolated enum RefsState: Equatable, Sendable {
  case idle
  case loading
  case loaded(RefInventory)
  case failed(String)

  var inventory: RefInventory? {
    if case .loaded(let inventory) = self { return inventory }
    return nil
  }

  var isLoading: Bool { self == .loading }
}

/// A repository's branches, as loaded for a ref menu.
nonisolated struct RefInventory: Equatable, Sendable {
  var local: [String]
  /// Remote-tracking refs (`origin/x`), without `*/HEAD`.
  var remote: [String]
  /// The repository's default remote branch, when known and present.
  var defaultBaseRef: String?
  /// The branch checked out at the repository root, which is where `git
  /// worktree add` starts a new branch when no default remote branch is
  /// known. Nil when the root is detached.
  var headBranch: String?
  /// Branch → path of the worktree that has it checked out.
  var checkedOut: [String: String]

  init(
    local: [String] = [], remote: [String] = [], defaultBaseRef: String? = nil, headBranch: String? = nil,
    checkedOut: [String: String] = [:]
  ) {
    self.local = local
    self.remote = remote
    self.defaultBaseRef = defaultBaseRef
    self.headBranch = headBranch
    self.checkedOut = checkedOut
  }

  /// From the four repository queries the worktree sheet also runs, for the
  /// repository at `repoRoot`.
  init(
    branchRefs: [String], localBranchNames: Set<String>, worktrees: [GitWtEntry], defaultRemoteBranchRef: String?,
    repoRoot: String
  ) {
    let locals = localBranchNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    let remotes = branchRefs.filter { !localBranchNames.contains($0) }
    let root = URL(fileURLWithPath: repoRoot).standardizedFileURL.path
    let rootBranch = worktrees.first { URL(fileURLWithPath: $0.path).standardizedFileURL.path == root }?.branch
      .trimmingCharacters(in: .whitespaces)
    self.init(
      local: locals,
      remote: remotes,
      defaultBaseRef: defaultRemoteBranchRef.flatMap { branchRefs.contains($0) ? $0 : nil },
      headBranch: rootBranch.flatMap { localBranchNames.contains($0) ? $0 : nil },
      checkedOut: Dictionary(
        worktrees.compactMap { entry in
          let branch = entry.branch.trimmingCharacters(in: .whitespaces)
          return branch.isEmpty ? nil : (branch, entry.path)
        },
        uniquingKeysWith: { first, _ in first }))
  }

  /// What a new branch with no base chosen starts from: the default
  /// remote branch, else the branch the repository root is on.
  var defaultBase: String? {
    defaultBaseRef ?? headBranch
  }

  func contains(_ ref: String) -> Bool {
    local.contains(ref) || remote.contains(ref)
  }

  /// The worktree already holding the branch that checking out `ref` would
  /// need, if any — git keeps a branch in one worktree at a time. A remote
  /// ref is checked out as its local twin, so the twin decides for it.
  func checkoutHolder(for ref: String) -> String? {
    if local.contains(ref) { return checkedOut[ref] }
    guard remote.contains(ref), let branch = WorkspaceCheckout.splitRemoteRef(ref)?.branch else { return nil }
    return checkedOut[branch]
  }
}
