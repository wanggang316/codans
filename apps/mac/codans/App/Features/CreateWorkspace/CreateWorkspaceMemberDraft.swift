import CodansCore
import Foundation

/// One project in the New Workspace sheet and everything the user can
/// decide about it. Pure state: the reducer derives issues and the
/// `WorkspacePlan.Member` from it.
nonisolated struct MemberDraft: Equatable, Identifiable, Sendable {
  /// Where the repository comes from. The sheet tells a registered project
  /// from a folder picked on disk for display; the plan only knows local
  /// roots and remotes.
  enum Source: Equatable, Sendable {
    case project(ProjectID, name: String, gitRoot: String)
    case localRepo(gitRoot: String)
    /// Cloned into `cloneDestination` first, then used like a local source.
    case remote(url: String, cloneDestination: String)

    var planSource: WorkspacePlan.Member.Source {
      switch self {
      case .project(_, _, let gitRoot), .localRepo(let gitRoot):
        return .local(gitRoot: gitRoot)
      case .remote(let url, let cloneDestination):
        return .remote(url: url, cloneDestination: cloneDestination)
      }
    }

    /// The local path this source is (or will be) read from.
    var gitRoot: String { planSource.gitRoot }

    var isRemote: Bool {
      if case .remote = self { return true }
      return false
    }

    /// The repository's own name.
    var title: String {
      switch self {
      case .project(_, let name, _): return name
      case .localRepo(let gitRoot): return (gitRoot as NSString).lastPathComponent
      case .remote(let url, let cloneDestination):
        return WorkspaceLayout.repositoryName(fromRemoteURL: url) ?? (cloneDestination as NSString).lastPathComponent
      }
    }

    /// Where it comes from: a home-relative path, or the URL.
    var location: String {
      switch self {
      case .project(_, _, let gitRoot), .localRepo(let gitRoot):
        return (gitRoot as NSString).abbreviatingWithTildeInPath
      case .remote(let url, _):
        return url
      }
    }

    /// The checkout folder a new member gets: the repository's folder name.
    var suggestedName: String {
      switch self {
      case .project(_, _, let gitRoot), .localRepo(let gitRoot):
        return (gitRoot as NSString).lastPathComponent
      case .remote:
        return title
      }
    }
  }

  enum CheckoutMode: Equatable, Sendable, CaseIterable {
    case newBranch
    /// One list of branches: a local one is checked out as it is, a remote
    /// one gets a local branch that tracks it.
    case existing

    var title: String {
      switch self {
      case .newBranch: return "New branch"
      case .existing: return "Existing branch"
      }
    }
  }

  /// What to do when a remote-tracking checkout meets a local branch of the
  /// same name. Keep is the default; reset is never implied.
  enum LocalConflictResolution: Equatable, Sendable {
    case keepLocal
    case resetToRemote
  }

  enum RefsState: Equatable, Sendable {
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

  enum Progress: Equatable, Sendable {
    case pending
    case running(WorkspaceCreationEvent.Phase, lastLine: String?)
    case done
    case failed(String)
    case rolledBack
  }

  let id: UUID
  var source: Source
  /// Folder under the workspace root.
  var name: String
  var mode: CheckoutMode = .newBranch
  /// New branch: its name. Empty is named after the workspace title.
  var branchOverride = ""
  /// New branch: where it starts. Nil is the repository's default branch.
  var baseRef: String?
  /// Existing branch: the branch to check out, local (`feature`) or
  /// remote-tracking (`origin/feature`).
  var existingRef: String?
  var localConflict: LocalConflictResolution = .keepLocal
  var refs: RefsState = .idle
  /// Findings from the client's preflight for this member.
  var preflightIssues: [WorkspacePreflight.Issue] = []
  var progress: Progress = .pending

  init(id: UUID, source: Source, name: String) {
    self.id = id
    self.source = source
    self.name = name
  }

  /// The branch the checkout ends up on. `defaultBranch` names a new branch
  /// the user left blank.
  func branch(defaultBranch: String) -> String {
    switch mode {
    case .newBranch:
      let own = branchOverride.trimmingCharacters(in: .whitespacesAndNewlines)
      return own.isEmpty ? defaultBranch : own
    case .existing:
      guard let existingRef else { return "" }
      return existingRefIsRemote ? (remoteRefBranch ?? "") : existingRef
    }
  }

  /// Whether the chosen branch is a remote-tracking ref, which is checked
  /// out as a local branch that tracks it. The repository's own lists
  /// decide; before they load, only the `<remote>/<branch>` shape can, and
  /// an unloaded repository blocks creation anyway.
  var existingRefIsRemote: Bool {
    guard let existingRef else { return false }
    if let inventory = refs.inventory {
      if inventory.local.contains(existingRef) { return false }
      if inventory.remote.contains(existingRef) { return true }
    }
    return WorkspaceCheckout.splitRemoteRef(existingRef) != nil
  }

  /// The branch part of the chosen remote ref.
  var remoteRefBranch: String? {
    guard existingRefIsRemote else { return nil }
    return existingRef.flatMap(WorkspaceCheckout.splitRemoteRef)?.branch
  }

  /// True when the chosen remote branch already exists locally, so the Keep
  /// / Reset choice applies.
  var hasLocalConflict: Bool {
    guard mode == .existing, let branch = remoteRefBranch, let inventory = refs.inventory else {
      return false
    }
    return inventory.local.contains(branch)
  }
}

/// The dialog that adds a project to the sheet's list or edits one in it.
/// Each kind sets its source one way: an open project is fixed when the
/// dialog opens, a folder comes from the folder picker, a remote from the
/// URL field. The list only changes on Add / Save.
nonisolated struct MemberEditor: Equatable, Identifiable, Sendable {
  enum Kind: Equatable, Sendable {
    /// A project open in codans, picked from the sheet's menu.
    case project
    /// Any repository folder on this Mac.
    case folder
    case remote
    case edit
  }

  /// Also the draft's id, so a new draft keeps one refs load across source
  /// changes and an edited one maps back to its row.
  let id: UUID
  let kind: Kind
  var draft: MemberDraft?
  /// Remote: the URL as typed. The draft follows it once it reads as a URL.
  var urlText = ""
  /// Why the chosen folder or the URL can't be used.
  var sourceIssue: String?
  var isResolvingSource = false
  /// The folder name was typed; a new source no longer renames it.
  var nameEditedManually = false

  init(id: UUID, kind: Kind, draft: MemberDraft? = nil) {
    self.id = id
    self.kind = kind
    self.draft = draft
    if case .remote(let url, _) = draft?.source {
      urlText = url
    }
  }

  var isNew: Bool { kind != .edit }

  /// Remote: the draft is for the URL in the field, not an earlier one.
  var isURLApplied: Bool {
    guard kind == .remote else { return true }
    guard case .remote(let url, _) = draft?.source else { return false }
    return AddEntryClassifier.normalizedRemoteKey(urlText) == AddEntryClassifier.normalizedRemoteKey(url)
  }
}

/// Branches a member's repository offers, as loaded for the sheet.
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

  /// From `ls-remote` on a remote that is not cloned yet: everything is a
  /// remote-tracking ref of the `origin` the clone will have.
  init(remoteHeads: RemoteHeads) {
    self.init(
      local: [],
      remote: remoteHeads.branches.map { "origin/\($0)" },
      defaultBaseRef: remoteHeads.defaultBranch.map { "origin/\($0)" },
      checkedOut: [:])
  }

  /// What a new branch with no base chosen starts from: the default
  /// remote branch, else the branch the repository root is on.
  var defaultBase: String? {
    defaultBaseRef ?? headBranch
  }

  func contains(_ ref: String) -> Bool {
    local.contains(ref) || remote.contains(ref)
  }
}

/// Something the sheet has to say about a member or the workspace.
nonisolated struct MemberIssue: Equatable, Sendable {
  enum Severity: Equatable, Sendable {
    /// A real problem; shown and blocks Create.
    case blocking
    /// Something not filled in yet; blocks Create without being shown as an
    /// error, since an empty form is not a mistake.
    case incomplete
    case warning
    case info
  }

  var severity: Severity
  var message: String

  static func blocking(_ message: String) -> MemberIssue { MemberIssue(severity: .blocking, message: message) }
  static func incomplete(_ message: String) -> MemberIssue { MemberIssue(severity: .incomplete, message: message) }
  static func warning(_ message: String) -> MemberIssue { MemberIssue(severity: .warning, message: message) }
  static func info(_ message: String) -> MemberIssue { MemberIssue(severity: .info, message: message) }

  init(severity: Severity, message: String) {
    self.severity = severity
    self.message = message
  }

  /// A preflight finding: informational ones only describe what will happen.
  init(preflight issue: WorkspacePreflight.Issue) {
    self.init(severity: issue.isInformational ? .info : .blocking, message: issue.message)
  }

  var blocksCreation: Bool { severity == .blocking || severity == .incomplete }
}
