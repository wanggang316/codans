import CodansCore
import Foundation
import Observation

/// The workflow definitions every GUI surface lists — the toolbar's Run
/// Workflow menu, the Agents View row menu, Settings → Workflows — kept
/// current by watching the files instead of rescanning on demand. A
/// workflow an agent writes from inside a pane shows up while codans stays
/// frontmost, and an edit saved in an editor revalidates by itself.
///
/// Watched: the user directory, and every local worktree's
/// `.codans/workflows` (or, until it exists, the nearest existing ancestor
/// up to the worktree root, so its creation is seen), plus each file in
/// those directories for editors that save in place. Events are coalesced
/// and only the scope that changed is rescanned, off the main actor.
/// Discovery itself stays cacheless; this is the app's one cache and it is
/// invalidated by the filesystem, not by guessing.
@MainActor
@Observable
final class WorkflowCatalogStore {
  private(set) var bundle: [WorkflowCatalogEntry] = []
  private(set) var user: [WorkflowCatalogEntry] = []
  /// Repository-scope entries keyed by worktree root path.
  private(set) var repositories: [String: [WorkflowCatalogEntry]] = [:]

  @ObservationIgnored private let discovery: WorkflowDiscovery
  @ObservationIgnored private var watches: [Key: WorkflowPathWatch] = [:]
  @ObservationIgnored private var trackedRoots: Set<String> = []
  @ObservationIgnored private var dirty: Set<Key> = []
  @ObservationIgnored private var flushTask: Task<Void, Never>?

  nonisolated private enum Key: Hashable, Sendable {
    case user
    case repository(root: String)
  }

  init(discovery: WorkflowDiscovery) {
    self.discovery = discovery
  }

  /// What a run in `worktreePath` would resolve against: bundle, user and
  /// that worktree's repository scope, shadowing applied.
  func catalog(forWorktreePath worktreePath: String?) -> [WorkflowCatalogEntry] {
    let repository = worktreePath.flatMap { repositories[$0] } ?? []
    return WorkflowDiscovery.resolveShadowing(bundle + user + repository)
  }

  /// Follows the hierarchy's local worktrees for the life of the app.
  func follow(_ hierarchy: HierarchyManager) {
    if let bundleDirectory = discovery.bundleDirectory {
      bundle = WorkflowDiscovery.scan(directory: bundleDirectory, scope: .bundle)
    }
    try? FileManager.default.createDirectory(at: discovery.userDirectory, withIntermediateDirectories: true)
    markDirty([.user])
    observe(hierarchy)
  }

  /// Set by the toolbar's "New Workflow…" and consumed by Settings →
  /// Workflows, which opens its sheet — held here so the request survives
  /// the Settings window still opening.
  private(set) var isNewWorkflowRequested = false

  func requestNewWorkflow() {
    isNewWorkflowRequested = true
  }

  func consumeNewWorkflowRequest() -> Bool {
    defer { isNewWorkflowRequested = false }
    return isNewWorkflowRequested
  }

  /// Rescans every watched scope now — the Settings refresh button.
  func rescanAll() {
    markDirty(Set(trackedRoots.map { Key.repository(root: $0) }).union([.user]))
  }

  // MARK: - Hierarchy

  private func observe(_ hierarchy: HierarchyManager) {
    let roots = withObservationTracking {
      Self.localWorktreeRoots(in: hierarchy.catalog)
    } onChange: { [weak self, weak hierarchy] in
      Task { @MainActor in
        guard let self, let hierarchy else { return }
        self.observe(hierarchy)
      }
    }
    track(roots)
  }

  private static func localWorktreeRoots(in catalog: Catalog) -> Set<String> {
    var roots: Set<String> = []
    for project in catalog.projects where project.remoteHost == nil {
      for worktree in project.worktrees where !worktree.archived {
        roots.insert(worktree.path)
      }
    }
    return roots
  }

  private func track(_ roots: Set<String>) {
    let removed = trackedRoots.subtracting(roots)
    let added = roots.subtracting(trackedRoots)
    trackedRoots = roots
    for root in removed {
      watches[.repository(root: root)] = nil
      repositories[root] = nil
    }
    if !added.isEmpty { markDirty(Set(added.map { Key.repository(root: $0) })) }
  }

  // MARK: - Scanning

  private func markDirty(_ keys: Set<Key>) {
    dirty.formUnion(keys)
    guard flushTask == nil else { return }
    flushTask = Task { [weak self] in
      // Editors and agents write in bursts (temp file, rename, chmod);
      // one rescan per burst is enough.
      try? await Task.sleep(for: .milliseconds(200))
      await self?.flush()
    }
  }

  private func flush() async {
    let keys = dirty
    dirty = []
    flushTask = nil
    let discovery = discovery
    let scanned = await Task.detached(priority: .utility) { () -> [Key: [WorkflowCatalogEntry]] in
      var result: [Key: [WorkflowCatalogEntry]] = [:]
      for key in keys {
        result[key] = Self.scan(key, discovery: discovery)
      }
      return result
    }.value
    for (key, entries) in scanned {
      switch key {
      case .user:
        if user != entries { user = entries }
      case .repository(let root):
        // A worktree dropped while its scan was in flight stays dropped.
        guard trackedRoots.contains(root) else { continue }
        if repositories[root] != entries { repositories[root] = entries }
      }
      rewatch(key, files: entries.map(\.path))
    }
  }

  nonisolated private static func directory(for key: Key, discovery: WorkflowDiscovery) -> URL {
    switch key {
    case .user:
      return discovery.userDirectory
    case .repository(let root):
      return WorkflowDiscovery.repositoryDirectory(worktreeRoot: URL(fileURLWithPath: root, isDirectory: true))
    }
  }

  nonisolated private static func scan(_ key: Key, discovery: WorkflowDiscovery) -> [WorkflowCatalogEntry] {
    let scope: WorkflowScope = key == .user ? .user : .repo
    return WorkflowDiscovery.scan(directory: directory(for: key, discovery: discovery), scope: scope)
  }

  private func rewatch(_ key: Key, files: [String]) {
    let directory = Self.directory(for: key, discovery: discovery)
    let stop: URL? =
      if case .repository(let root) = key { URL(fileURLWithPath: root, isDirectory: true) } else { nil }
    watches[key] = WorkflowPathWatch(
      directory: directory, stopAt: stop, files: files,
      onChange: { [weak self] in
        Task { @MainActor in self?.markDirty([key]) }
      })
  }
}

/// Kernel-queue watches on one workflow directory (or its nearest existing
/// ancestor) and the files in it. Dropping the value cancels them all.
/// `nonisolated` because the app target defaults to the main actor: the
/// event and cancel handlers run on a dispatch queue, and a main-actor
/// closure there traps on the isolation check.
nonisolated final class WorkflowPathWatch: @unchecked Sendable {
  private var sources: [DispatchSourceFileSystemObject] = []
  private static let queue = DispatchQueue(label: "codans.workflow-catalog.watch", qos: .utility)

  init(directory: URL, stopAt: URL?, files: [String], onChange: @escaping @Sendable () -> Void) {
    var target = directory
    let fileManager = FileManager.default
    while !fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
      let parent = target.deletingLastPathComponent()
      if let stopAt, target.standardizedFileURL.path == stopAt.standardizedFileURL.path { break }
      if parent.path == target.path { break }
      target = parent
    }
    watch(target.path(percentEncoded: false), onChange: onChange)
    if target.standardizedFileURL.path == directory.standardizedFileURL.path {
      for file in files { watch(file, onChange: onChange) }
    }
  }

  deinit {
    for source in sources { source.cancel() }
  }

  private func watch(_ path: String, onChange: @escaping @Sendable () -> Void) {
    let descriptor = open(path, O_EVTONLY)
    guard descriptor >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: Self.queue)
    source.setEventHandler(handler: onChange)
    source.setCancelHandler { close(descriptor) }
    source.resume()
    sources.append(source)
  }
}
