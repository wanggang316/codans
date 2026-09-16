import CodansCore
import Foundation

/// One row of the New Workspace sheet: a repository the workspace will
/// check out, with everything the user can decide about it. Pure state —
/// the reducer derives issues and the `WorkspacePlan.Member` from it.
nonisolated struct MemberDraft: Equatable, Identifiable, Sendable {
  /// Where the repository comes from. The sheet keeps the four flavours
  /// apart for display; the plan only knows local roots and remotes.
  enum Source: Equatable, Sendable {
    case project(ProjectID, gitRoot: String)
    case localRepo(gitRoot: String)
    case bareRepo(gitRoot: String)
    case remote(url: String, cloneDestination: String, destinationEditedManually: Bool)

    var planSource: WorkspacePlan.Member.Source {
      switch self {
      case .project(_, let gitRoot), .localRepo(let gitRoot), .bareRepo(let gitRoot):
        return .local(gitRoot: gitRoot)
      case .remote(let url, let cloneDestination, _):
        return .remote(url: url, cloneDestination: cloneDestination)
      }
    }

    /// The local path this source is (or will be) read from.
    var gitRoot: String { planSource.gitRoot }

    var isRemote: Bool {
      if case .remote = self { return true }
      return false
    }

    /// Path or host shown next to the name.
    var displayLocation: String {
      switch self {
      case .project(_, let gitRoot), .localRepo(let gitRoot), .bareRepo(let gitRoot):
        return (gitRoot as NSString).abbreviatingWithTildeInPath
      case .remote(let url, _, _):
        return url
      }
    }

    /// A folder name the source suggests: the repository folder, the bare
    /// directory without `.git`, or the remote's repository name.
    var suggestedName: String {
      switch self {
      case .project(_, let gitRoot), .localRepo(let gitRoot):
        return (gitRoot as NSString).lastPathComponent
      case .bareRepo(let gitRoot):
        let last = (gitRoot as NSString).lastPathComponent
        return last.lowercased().hasSuffix(".git") && last.count > 4 ? String(last.dropLast(4)) : last
      case .remote(let url, let cloneDestination, _):
        return WorkspaceLayout.repositoryName(fromRemoteURL: url)
          ?? (cloneDestination as NSString).lastPathComponent
      }
    }
  }

  enum CheckoutMode: Equatable, Sendable, CaseIterable {
    case newBranch
    case existingLocal
    case existingRemote

    var title: String {
      switch self {
      case .newBranch: return "New branch"
      case .existingLocal: return "Existing branch"
      case .existingRemote: return "Remote branch"
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

    var isRunning: Bool {
      if case .running = self { return true }
      return false
    }
  }

  let id: UUID
  var source: Source
  /// Folder under the workspace root; also the row's display name.
  var name: String
  var nameEditedManually = false
  var mode: CheckoutMode = .newBranch
  /// Branch to create or check out. In remote mode it follows the ref's
  /// branch part until edited.
  var branch: String
  var branchEditedManually = false
  /// Base for a new branch; nil means the repository's default.
  var baseRef: String?
  var baseRefEditedManually = false
  /// `origin/feature`, remote mode only.
  var remoteRef: String?
  var localConflict: LocalConflictResolution = .keepLocal
  var refs: RefsState = .idle
  /// Findings from the client's preflight, keyed off this row.
  var asyncIssues: [MemberIssue] = []
  var progress: Progress = .pending

  init(id: UUID, source: Source, name: String, branch: String, baseRef: String? = nil) {
    self.id = id
    self.source = source
    self.name = name
    self.branch = branch
    self.baseRef = baseRef
  }

  /// The branch name a remote ref implies, when one is chosen.
  var remoteRefBranch: String? {
    remoteRef.flatMap(WorkspaceCheckout.splitRemoteRef)?.branch
  }

  /// True when the chosen remote ref's branch already exists locally, so the
  /// Keep / Reset choice applies.
  var hasLocalConflict: Bool {
    guard mode == .existingRemote, let inventory = refs.inventory else { return false }
    return inventory.local.contains(branch)
  }
}

/// Branches a member's repository offers, as loaded for the sheet.
nonisolated struct RefInventory: Equatable, Sendable {
  var local: [String]
  /// Remote-tracking refs (`origin/x`), without `*/HEAD`.
  var remote: [String]
  /// The repository's default remote branch, when known and present.
  var defaultBaseRef: String?
  /// Branch → path of the worktree that has it checked out.
  var checkedOut: [String: String]

  init(local: [String] = [], remote: [String] = [], defaultBaseRef: String? = nil, checkedOut: [String: String] = [:]) {
    self.local = local
    self.remote = remote
    self.defaultBaseRef = defaultBaseRef
    self.checkedOut = checkedOut
  }

  /// From the four repository queries the worktree sheet also runs.
  init(branchRefs: [String], localBranchNames: Set<String>, worktrees: [GitWtEntry], defaultRemoteBranchRef: String?) {
    let locals = localBranchNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    let remotes = branchRefs.filter { !localBranchNames.contains($0) }
    self.init(
      local: locals,
      remote: remotes,
      defaultBaseRef: defaultRemoteBranchRef.flatMap { branchRefs.contains($0) ? $0 : nil },
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

  func contains(_ ref: String) -> Bool {
    local.contains(ref) || remote.contains(ref)
  }

  func options(includeLocal: Bool, includeRemote: Bool) -> [BranchRefOption] {
    var result: [BranchRefOption] = []
    if includeLocal {
      result += local.map { BranchRefOption(shortName: $0, isRemote: false, checkedOutAt: checkedOut[$0]) }
    }
    if includeRemote {
      result += remote.map { BranchRefOption(shortName: $0, isRemote: true, isDefault: $0 == defaultBaseRef) }
    }
    return result
  }
}

/// One choice in a ref picker.
nonisolated struct BranchRefOption: Identifiable, Equatable, Sendable {
  var id: String { shortName }
  let shortName: String
  let isRemote: Bool
  var isDefault = false
  /// Set when another worktree holds the branch; the row is offered but
  /// disabled, with the path as the reason.
  var checkedOutAt: String?
}

/// Something the sheet has to say about a row or the workspace as a whole,
/// anchored to the field it concerns.
nonisolated struct MemberIssue: Equatable, Sendable {
  enum Severity: Equatable, Sendable {
    /// Disables Create.
    case blocking
    case warning
    case info
  }

  enum Field: Equatable, Sendable {
    case name
    case branch
    case baseRef
    case remoteRef
    case cloneDestination
    case refs
    case row
  }

  var severity: Severity
  var field: Field
  var message: String

  static func blocking(_ field: Field, _ message: String) -> MemberIssue {
    MemberIssue(severity: .blocking, field: field, message: message)
  }

  static func warning(_ field: Field, _ message: String) -> MemberIssue {
    MemberIssue(severity: .warning, field: field, message: message)
  }

  static func info(_ field: Field, _ message: String) -> MemberIssue {
    MemberIssue(severity: .info, field: field, message: message)
  }

  init(severity: Severity, field: Field, message: String) {
    self.severity = severity
    self.field = field
    self.message = message
  }

  /// A preflight finding, placed on the field its kind concerns.
  init(preflight issue: WorkspacePreflight.Issue) {
    let field: Field
    switch issue.kind {
    case .destinationExists: field = .name
    case .cloneDestinationTaken, .cloneDestinationReused: field = .cloneDestination
    case .invalidBranchName: field = .branch
    case .rootAlreadyRegistered, .rootIsFile, .rootAlreadyWorkspace, .rootInsideRepository, .rootExists,
      .sourceNotRepository:
      field = .row
    }
    self.init(severity: issue.isInformational ? .info : .blocking, field: field, message: issue.message)
  }
}
