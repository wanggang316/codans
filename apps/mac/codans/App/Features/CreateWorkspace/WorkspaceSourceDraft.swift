import CodansCore
import Foundation

/// One source project in the Add Workspace / Add Project sheet. A source is
/// a main checkout the `default` group references as it is: no branch is
/// chosen and nothing is checked out.
nonisolated struct SourceDraft: Equatable, Identifiable, Sendable {
  /// Where the repository comes from. The sheet tells a registered project
  /// from a folder picked on disk for display; the plan only knows local
  /// paths and remotes.
  enum Source: Equatable, Sendable {
    case project(ProjectID, name: String, gitRoot: String)
    case localRepo(gitRoot: String)
    /// Cloned into `cloneDestination` first, then used like a local source.
    case remote(url: String, cloneDestination: String)

    var workspaceSource: WorkspaceSource {
      switch self {
      case .project(_, _, let gitRoot), .localRepo(let gitRoot):
        return WorkspaceSource(location: .local(path: gitRoot))
      case .remote(let url, let cloneDestination):
        return WorkspaceSource(location: .remote(url: url, cloneDestination: cloneDestination))
      }
    }

    /// The local path this source is (or will be) read from.
    var gitRoot: String {
      switch self {
      case .project(_, _, let gitRoot), .localRepo(let gitRoot): return gitRoot
      case .remote(_, let cloneDestination): return cloneDestination
      }
    }

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
  }

  let id: UUID
  var source: Source
  /// Findings from the client's preflight for this source.
  var preflightIssues: [WorkspacePreflight.Issue] = []

  init(id: UUID, source: Source) {
    self.id = id
    self.source = source
  }
}

/// The Add Remote dialog: a URL and the folder it is cloned into. The list
/// only changes on Add / Save.
nonisolated struct RemoteSourceEditor: Equatable, Identifiable, Sendable {
  /// Also the draft's id, so an edited remote maps back to its row.
  let id: UUID
  let isNew: Bool
  /// The remote as the URL field last applied it.
  var draft: SourceDraft?
  /// The URL as typed. The draft follows it once it reads as a URL.
  var urlText = ""
  /// Why the URL can't be used.
  var sourceIssue: String?

  init(id: UUID, isNew: Bool, draft: SourceDraft? = nil) {
    self.id = id
    self.isNew = isNew
    self.draft = draft
    if case .remote(let url, _) = draft?.source {
      urlText = url
    }
  }

  /// The draft is for the URL in the field, not an earlier one.
  var isURLApplied: Bool {
    guard case .remote(let url, _) = draft?.source else { return false }
    return AddEntryClassifier.normalizedRemoteKey(urlText) == AddEntryClassifier.normalizedRemoteKey(url)
  }
}

/// Something the sheet has to say about a field, a source, or a member.
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
