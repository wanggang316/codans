import Foundation

/// Per-Project health signal driven at runtime by `ProjectReconciler`.
/// Intentionally **transient** — not encoded into `catalog.json`. Every decode
/// produces `.loading`; the reconciler transitions the value on its first pass
/// after launch (and on window focus / Retry). Keeping this out of `Codable`
/// avoids a catalog-schema bump and keeps pre-existing catalogs round-trip
/// identical.
public nonisolated enum ProjectLoadState: Equatable, Sendable {
  case loading
  case ready
  case failed(reason: String)
}

public nonisolated struct Project: Equatable, Sendable, Identifiable {
  public var id: ProjectID
  /// User-set display override. `nil` means the project shows under its
  /// canonical name — the last path component of `rootPath`. Renaming via
  /// Settings → General → Name writes here; clearing the field writes `nil`.
  /// Persistence-only; `name` is still the right thing to read at call sites.
  public var displayName: String?
  /// For a local project, the canonical local root path. For a Remote Project
  /// (`remoteHost != nil`), the **remote** absolute path on the host — the same
  /// string plumbing carries it, but it is never a valid local filesystem path,
  /// so local-FS operations must be gated on `isRemote`.
  public var rootPath: String
  /// Resolved git repository root. For a Remote Project this is a **remote** path
  /// string (discovered over SSH), `nil` when the remote root is a plain folder.
  public var gitRoot: String?
  /// The Host record (`Catalog.hosts`) this Remote Project is on. `nil` = a
  /// local Project, on This Mac. Persisted in place of the host fields
  /// (ADR 0003).
  public var hostID: HostID?
  /// SSH destination this project lives on. `nil` = local. When set, `rootPath` /
  /// `gitRoot` / each `Worktree.path` are remote path strings and terminals/git
  /// run over SSH. See `RemoteHost`.
  ///
  /// Resolved from `hostID` by the catalog (`Catalog.resolveHostReferences`)
  /// so runtime code reads the connection without a Host lookup. Not
  /// persisted when `hostID` is set; a value without a `hostID` comes from a
  /// legacy catalog and is turned into a Host record on load.
  public var remoteHost: RemoteHost?
  public var worktrees: [Worktree]
  public var selectedWorktreeID: WorktreeID?
  /// Sidebar disclosure state for this Project's worktree group. Defaults to
  /// `true` so newly added Projects reveal their worktrees immediately.
  /// Persisted via the standard catalog save pipeline so the open/closed
  /// choice survives app restarts.
  public var isExpanded: Bool
  /// User-assigned tag membership. Set semantics in memory; encoded as a
  /// sorted `[TagID]` so `git diff catalog.json` is order-stable. Default
  /// empty — projects start untagged.
  public var tagIDs: Set<TagID>
  /// Wall-clock timestamp at which this Project was added to the catalog.
  /// A catalog that still stores the retired `joinOrder` sort is sorted by
  /// this field one time at load (see `LegacyProjectOrder`). Legacy catalogs
  /// that predate this field decode to `.distantPast`.
  public var addedAt: Date
  /// Most-recent activity timestamp. Bumped on (a) inbox-notification
  /// arrival for any worktree of this Project, and (b) any input the
  /// app dispatches into a pane of this Project. `nil` = never active.
  /// A catalog that still stores the retired `activeFirst` sort is sorted by
  /// this field one time at load (see `LegacyProjectOrder`).
  public var lastActiveAt: Date?
  /// User-assigned Project accent. `nil` = no color (system accent).
  /// Edited via Settings → Projects → General. Encoded only when set so
  /// catalogs without a color stay byte-identical on round-trip.
  public var color: ProjectColor?
  /// User-picked Project glyph. `nil` = the built-in folder pair (see
  /// `ProjectIcon`). Edited via Settings → Projects → General → Icon.
  /// Encoded only when set so catalogs without an icon stay byte-identical
  /// on round-trip.
  public var icon: ProjectIcon?
  /// `true` when `rootPath` is a workspace: a plain folder holding groups of
  /// checkouts described by `<root>/.codans/workspace-groups.json`. The
  /// Project itself is the sidebar header and stands for no row; every row
  /// carries a `workspaceSlot` (group terminal, reference, or member).
  /// Persisted (omitted when `false`) so the kind is known synchronously at
  /// launch and survives the root being temporarily unreachable; the
  /// catalog load path re-derives it from the manifest on disk when an older
  /// build has stripped the key. Sticky: it is never cleared because the
  /// manifest went missing — see `ProjectKind`.
  public var isWorkspace: Bool
  /// Workspace groups, `default` first and then named groups in creation
  /// order. A cache of the group manifest for synchronous launch rendering,
  /// plus sidebar state (`isExpanded`, `deletion`). Empty for other
  /// Projects; the encode path omits the key when empty.
  public var workspaceGroups: [WorkspaceGroupRecord]
  /// Transient. The decoded group manifest, filled by the workspace
  /// reconcile and used for display only (title, sources, group details).
  /// Nil until the first reconcile after launch; no catalog logic may depend
  /// on it.
  public var workspace: WorkspaceGroupsManifest?
  /// Transient. Reference rows whose source main checkout is missing on
  /// disk. The rows stay (the source is not the Workspace's to archive);
  /// the reconcile fills this so the sidebar can show them as unavailable.
  public var unavailableWorkspaceRows: Set<WorktreeID> = []
  /// Transient. See `ProjectLoadState` doc-comment.
  public var loadState: ProjectLoadState

  public init(
    id: ProjectID = ProjectID(),
    name: String,
    rootPath: String,
    gitRoot: String? = nil,
    hostID: HostID? = nil,
    remoteHost: RemoteHost? = nil,
    worktrees: [Worktree] = [],
    selectedWorktreeID: WorktreeID? = nil,
    isExpanded: Bool = true,
    tagIDs: Set<TagID> = [],
    addedAt: Date = Date(),
    lastActiveAt: Date? = nil,
    color: ProjectColor? = nil,
    icon: ProjectIcon? = nil,
    isWorkspace: Bool = false,
    workspaceGroups: [WorkspaceGroupRecord] = [],
    workspace: WorkspaceGroupsManifest? = nil,
    loadState: ProjectLoadState = .loading
  ) {
    self.id = id
    self.rootPath = rootPath
    // Compress the legacy `name:` argument into the canonical/override split.
    // A value equal to the canonical (or empty) means "no override" — keeps
    // every existing caller (tests, addProject) source-compatible while the
    // semantics of `Project.name` move under the hood.
    let canonical = (rootPath as NSString).lastPathComponent
    self.displayName = (name.isEmpty || name == canonical) ? nil : name
    self.gitRoot = gitRoot
    self.hostID = hostID
    self.remoteHost = remoteHost
    self.worktrees = worktrees
    self.selectedWorktreeID = selectedWorktreeID
    self.isExpanded = isExpanded
    self.tagIDs = tagIDs
    self.addedAt = addedAt
    self.lastActiveAt = lastActiveAt
    self.color = color
    self.icon = icon
    self.isWorkspace = isWorkspace
    self.workspaceGroups = workspaceGroups
    self.workspace = workspace
    self.loadState = loadState
  }

  /// A Project supports Git-backed Worktree operations only when it has a resolved git root.
  /// For non-git Projects, the UI presents a single synthetic Worktree (`Project.rootPath`)
  /// and the "Add Worktree" affordance is suppressed. Holds for remote git repos too — a
  /// Remote Project with a resolved (remote) git root supports worktree operations over SSH.
  /// A workspace answers `false`: its rows are checkouts of *other* repositories, added
  /// through the workspace flow rather than `git worktree add` on a project root.
  public var supportsWorktrees: Bool { gitRoot != nil }

  /// The repository a Worktree row's git operations run against: the row's
  /// own `sourceGitRoot` when it is a workspace child, else the Project's
  /// `gitRoot`. Nil for the root row of a dir-kind or workspace Project.
  public func repoRoot(for worktree: Worktree) -> String? {
    worktree.sourceGitRoot ?? gitRoot
  }

  /// `true` when `worktree` is the Project's main checkout — the row whose
  /// path is the Project root. For a workspace this is the root folder row.
  public func isMainCheckout(_ worktree: Worktree) -> Bool {
    worktree.path == rootPath
  }

  /// The worktree an agent starts in when the Project has one place to
  /// work (a folder or a workspace): the selected row, else the first one
  /// that is not archived.
  public var soleWorkingWorktree: Worktree? {
    worktrees.first { $0.id == selectedWorktreeID && !$0.archived }
      ?? worktrees.first { !$0.archived }
  }

  /// True for a Remote Project — its `rootPath` / `gitRoot` / worktree paths are
  /// remote, and terminals / git run over SSH. Local-filesystem operations
  /// (`FileManager`, `URL(fileURLWithPath:)`, symlink resolution, reveal-in-Finder)
  /// must be gated on this being `false`.
  public var isRemote: Bool { remoteHost != nil }

  /// Path-derived fallback name. Identical to `name` when the user hasn't
  /// set a custom `displayName`. Worktree base-directory resolution uses
  /// this so renaming a project never relocates its worktrees on disk.
  public var canonicalName: String {
    (rootPath as NSString).lastPathComponent
  }

  /// Effective name shown in sidebars, the Settings header, and any other
  /// label surface. Reads through the override → canonical chain so a
  /// `nil` `displayName` transparently renders as the canonical name.
  public var name: String { displayName ?? canonicalName }
}

extension Project: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, name, displayName, rootPath, gitRoot, hostID, remoteHost, worktrees, selectedWorktreeID,
      isExpanded, tagIDs, addedAt, lastActiveAt, color, icon, isWorkspace, workspaceGroups
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(ProjectID.self, forKey: .id)
    self.rootPath = try container.decode(String.self, forKey: .rootPath)
    // Migration: prefer the explicit `displayName` key when present. Fall back
    // to the legacy `name` field — keeping it as the override only when it
    // differs from the canonical path-derived name (else it's redundant and
    // gets normalized away).
    let canonicalForDecode = (self.rootPath as NSString).lastPathComponent
    if let explicit = try container.decodeIfPresent(String.self, forKey: .displayName) {
      self.displayName = explicit.isEmpty ? nil : explicit
    } else if let legacy = try container.decodeIfPresent(String.self, forKey: .name) {
      self.displayName = (legacy.isEmpty || legacy == canonicalForDecode) ? nil : legacy
    } else {
      self.displayName = nil
    }
    self.gitRoot = try container.decodeIfPresent(String.self, forKey: .gitRoot)
    self.hostID = try container.decodeIfPresent(HostID.self, forKey: .hostID)
    // Legacy (catalog v4 and older) and the IPC project list carry the host
    // fields on the Project. With a `hostID` the catalog replaces them with
    // the endpoint of the Host record (`Catalog.resolveHostReferences`).
    self.remoteHost = try container.decodeIfPresent(RemoteHost.self, forKey: .remoteHost)
    self.worktrees = try container.decodeIfPresent([Worktree].self, forKey: .worktrees) ?? []
    self.selectedWorktreeID = try container.decodeIfPresent(WorktreeID.self, forKey: .selectedWorktreeID)
    self.isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
    let tagIDArray = try container.decodeIfPresent([TagID].self, forKey: .tagIDs) ?? []
    self.tagIDs = Set(tagIDArray)
    // Legacy catalogs ship without `addedAt`; fall back to `.distantPast`
    // so the load-time `joinOrder` sort ties on array position.
    self.addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? .distantPast
    self.lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt)
    self.color = try container.decodeIfPresent(ProjectColor.self, forKey: .color)
    // Deliberately lenient, unlike every sibling field: a malformed `icon`
    // degrades to the default folder glyph instead of throwing, because a
    // throw here fails the whole `catalog.json` decode and leaves the user
    // staring at an empty app over a cosmetic value. Hand-edited catalogs and
    // a future icon case written by a newer build both land in this branch.
    self.icon = try? container.decodeIfPresent(ProjectIcon.self, forKey: .icon)
    self.isWorkspace = try container.decodeIfPresent(Bool.self, forKey: .isWorkspace) ?? false
    self.workspaceGroups =
      try container.decodeIfPresent([WorkspaceGroupRecord].self, forKey: .workspaceGroups) ?? []
    self.workspace = nil
    self.loadState = .loading
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    // `name` is written verbatim as the effective (computed) name so older
    // builds that don't know about `displayName` still render the project
    // under the right label. `displayName` is the source of truth on read.
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(displayName, forKey: .displayName)
    try container.encode(rootPath, forKey: .rootPath)
    try container.encodeIfPresent(gitRoot, forKey: .gitRoot)
    // A Remote Project stores only its Host id; the Host fields live in
    // `Catalog.hosts`. A Remote Project without a Host id (not yet attached
    // to a record) keeps the legacy fields so the connection is never lost;
    // the next load turns them into a Host record.
    if let hostID {
      try container.encode(hostID, forKey: .hostID)
    } else {
      try container.encodeIfPresent(remoteHost, forKey: .remoteHost)
    }
    try container.encode(worktrees, forKey: .worktrees)
    try container.encodeIfPresent(selectedWorktreeID, forKey: .selectedWorktreeID)
    // Only emit `isExpanded` when collapsed — keeps the common case
    // (expanded) byte-identical on round-trip.
    if !isExpanded {
      try container.encode(false, forKey: .isExpanded)
    }
    // Stable on-disk ordering for set-typed memory: sort by raw UUID string.
    // Omit the key entirely when the project carries no tags.
    if !tagIDs.isEmpty {
      let sorted = tagIDs.sorted { $0.raw.uuidString < $1.raw.uuidString }
      try container.encode(sorted, forKey: .tagIDs)
    }
    // Sentinel addedAt (from legacy decode) is omitted so legacy
    // catalogs stay byte-identical until something actually populates
    // the timestamp.
    if addedAt != .distantPast {
      try container.encode(addedAt, forKey: .addedAt)
    }
    try container.encodeIfPresent(lastActiveAt, forKey: .lastActiveAt)
    try container.encodeIfPresent(color, forKey: .color)
    try container.encodeIfPresent(icon, forKey: .icon)
    // Omit `isWorkspace` when false so every non-workspace catalog stays
    // byte-identical on round-trip.
    if isWorkspace {
      try container.encode(true, forKey: .isWorkspace)
    }
    if !workspaceGroups.isEmpty {
      try container.encode(workspaceGroups, forKey: .workspaceGroups)
    }
    // `workspace` and `loadState` intentionally not encoded (transient).
  }
}
