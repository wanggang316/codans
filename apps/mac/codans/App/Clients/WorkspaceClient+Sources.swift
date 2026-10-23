import CodansCore
import Foundation

// Workspace creation and the source project list. A source is a main
// checkout the `default` group references through a link; nothing here
// creates or switches a branch, and nothing touches a source directory.
extension WorkspaceClient {
  /// A source after resolution: its canonical main checkout (where the
  /// clone will land, for a remote not on disk yet), its link name, and the
  /// URL still to clone from, if any.
  struct ResolvedSource: Sendable {
    let name: String
    let sourceGitRoot: String
    let remoteURL: String?
    let cloneFrom: String?

    var manifestEntry: WorkspaceGroupsManifest.Source {
      WorkspaceGroupsManifest.Source(name: name, sourceGitRoot: sourceGitRoot, remoteURL: remoteURL)
    }
  }

  @MainActor
  static func createWorkspace(_ plan: WorkspaceSourcePlan, context: Context) async throws -> ProjectID {
    let title = plan.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw WorkspaceError.invalidSourcePlan(reason: "a workspace needs a title") }
    guard !plan.rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WorkspaceError.invalidSourcePlan(reason: "a workspace needs a folder")
    }
    let rootPath = canonical(plan.rootPath)
    try await preflightRoot(rootPath, context: context)
    var resolved: [ResolvedSource] = []
    for source in plan.sources {
      let entry = try await resolveSource(source, takenNames: Set(resolved.map(\.name)), context: context)
      guard !resolved.contains(where: { $0.sourceGitRoot == entry.sourceGitRoot }) else {
        throw WorkspaceError.sourceExists(path: entry.sourceGitRoot)
      }
      resolved.append(entry)
    }

    var ledger = WorkspaceMaterializationLedger()
    do {
      let fileManager = FileManager.default
      if !fileManager.fileExists(atPath: rootPath) {
        try fileManager.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
        ledger.record(.createdDirectory(path: rootPath))
      }
      for entry in resolved {
        try Task.checkCancellation()
        try await cloneIfNeeded(entry, ledger: &ledger, context: context)
      }
      // The root may be an existing folder; everything created inside it is
      // recorded so a failure leaves the folder as it was.
      let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
      let stateDirectory = WorkspaceLayout.stateDirectoryURL(rootURL: rootURL).path(percentEncoded: false)
      if !fileManager.fileExists(atPath: stateDirectory) {
        try fileManager.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        ledger.record(.createdDirectory(path: stateDirectory))
      }
      let defaultPath = WorkspaceLayout.uniquePath(base: rootURL, folder: WorkspaceLayout.defaultGroupName)
      let manifest = WorkspaceGroupsManifest(
        title: title,
        description: plan.description,
        taskLinks: plan.taskLinks,
        projects: resolved.map(\.manifestEntry),
        groups: [
          .init(
            id: .derived(rootPath: rootPath, key: WorkspaceLayout.defaultGroupName),
            name: WorkspaceLayout.defaultGroupName, kind: .default,
            path: (defaultPath as NSString).lastPathComponent)
        ])
      try WorkspaceManifestStore.saveGroups(manifest, rootPath: rootPath)
      ledger.record(
        .createdDirectory(path: WorkspaceLayout.groupsManifestURL(rootPath: rootPath).path(percentEncoded: false)))
      ledger.record(.createdDirectory(path: defaultPath))
      try WorkspaceDefaultLinks.sync(rootPath: rootPath, manifest: manifest)
    } catch {
      let failures = await rollback(ledger, context: context)
      if !failures.isEmpty {
        logger.warning("workspace creation left residue: \(failures.joined(separator: "; "), privacy: .private)")
      }
      throw error is CancellationError ? WorkspaceError.cancelled : error
    }

    let projectID = context.hierarchy.addWorkspaceProject(title, rootPath)
    await context.hierarchy.reconcileDiscoveredWorktrees(projectID)
    return projectID
  }

  @MainActor
  static func preflightWorkspace(_ plan: WorkspaceSourcePlan, context: Context) async -> WorkspacePreflight {
    var result = WorkspacePreflight()
    let trimmedRoot = plan.rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedRoot.isEmpty {
      let rootPath = canonical(trimmedRoot)
      do {
        try await preflightRoot(rootPath, context: context)
        if isDirectory(rootPath) {
          result.rootIssues.append(
            .init(kind: .rootExists, message: "The folder already exists. The workspace will be set up inside it."))
        }
      } catch let error as WorkspaceError {
        if let issue = preflightIssue(for: error) { result.rootIssues.append(issue) }
      } catch {
        result.rootIssues.append(.init(kind: .rootIsFile, message: describe(error)))
      }
    }
    var seen = Set<String>()
    for (index, source) in plan.sources.enumerated() {
      var issues: [WorkspacePreflight.Issue] = []
      do {
        let resolved = try await resolveSource(source, takenNames: [], context: context)
        if !seen.insert(resolved.sourceGitRoot).inserted {
          issues.append(
            .init(kind: .destinationExists, message: "\(tilde(resolved.sourceGitRoot)) is listed twice."))
        }
        if case .remote = source.location, resolved.cloneFrom == nil {
          issues.append(
            .init(
              kind: .cloneDestinationReused,
              message: "\(tilde(resolved.sourceGitRoot)) already holds a clone of this remote. It will be reused."))
        }
      } catch let error as WorkspaceError {
        if let issue = preflightIssue(for: error) { issues.append(issue) }
      } catch {
        issues.append(.init(kind: .sourceNotRepository, message: describe(error)))
      }
      if !issues.isEmpty {
        result.memberIssues[String(index)] = issues
      }
    }
    return result
  }

  @MainActor
  static func addSource(
    projectID: ProjectID, source: WorkspaceSource, context: Context
  ) async throws -> WorktreeID {
    let project = try workspaceProject(projectID, context: context)
    let rootPath = project.rootPath
    var manifest = try loadManifest(rootPath: rootPath)
    let entry = try await resolveSource(
      source, takenNames: takenSourceNames(manifest, rootPath: rootPath), context: context)
    guard !manifest.projects.contains(where: { canonical($0.sourceGitRoot) == entry.sourceGitRoot }) else {
      throw WorkspaceError.sourceExists(path: entry.sourceGitRoot)
    }

    var ledger = WorkspaceMaterializationLedger()
    do {
      try await cloneIfNeeded(entry, ledger: &ledger, context: context)
      manifest.projects.append(entry.manifestEntry)
      try saveManifest(manifest, rootPath: rootPath)
    } catch {
      _ = await rollback(ledger, context: context)
      throw error is CancellationError ? WorkspaceError.cancelled : error
    }
    syncLinks(rootPath: rootPath, manifest: manifest)
    await context.hierarchy.reconcileDiscoveredWorktrees(projectID)
    guard let row = referenceRows(in: projectID, sourceGitRoot: entry.sourceGitRoot, context: context).first
    else { throw WorkspaceError.memberNotRegistered(name: entry.name) }
    return row
  }

  @MainActor
  static func removeSource(projectID: ProjectID, sourceGitRoot: String, context: Context) async throws {
    let project = try workspaceProject(projectID, context: context)
    let rootPath = project.rootPath
    var manifest = try loadManifest(rootPath: rootPath)
    let target = canonical(sourceGitRoot)
    guard let index = manifest.projects.firstIndex(where: { canonical($0.sourceGitRoot) == target }) else {
      throw WorkspaceError.sourceNotFound(path: sourceGitRoot)
    }
    manifest.projects.remove(at: index)
    try saveManifest(manifest, rootPath: rootPath)
    // The sync removes only the link; the source directory is never reached.
    syncLinks(rootPath: rootPath, manifest: manifest)
    // Rows first: a reconcile leaves rows the manifest no longer names as
    // they are, so it would not drop the reference.
    context.hierarchy.removeWorkspaceRows(
      projectID, referenceRows(in: projectID, sourceGitRoot: target, context: context))
    await context.hierarchy.reconcileDiscoveredWorktrees(projectID)
  }

  // MARK: Helpers

  @MainActor
  static func workspaceProject(_ projectID: ProjectID, context: Context) throws -> Project {
    guard let project = context.hierarchy.snapshot().projects.first(where: { $0.id == projectID }),
      project.isWorkspace
    else { throw WorkspaceError.notWorkspace(projectID) }
    return project
  }

  /// The group manifest from disk, never the catalog's cached copy, so a
  /// write starts from what another instance may have written.
  static func loadManifest(rootPath: String) throws -> WorkspaceGroupsManifest {
    do {
      return try WorkspaceManifestStore.loadOrMigrate(rootPath: rootPath)
    } catch {
      throw WorkspaceError.manifestUnavailable(reason: String(describing: error))
    }
  }

  static func saveManifest(_ manifest: WorkspaceGroupsManifest, rootPath: String) throws {
    do {
      try WorkspaceManifestStore.saveGroups(manifest, rootPath: rootPath)
    } catch {
      throw WorkspaceError.manifestUnavailable(reason: String(describing: error))
    }
  }

  /// Link problems are notes, not failures: the manifest is already
  /// written, and the next reconcile syncs again.
  static func syncLinks(rootPath: String, manifest: WorkspaceGroupsManifest) {
    do {
      let report = try WorkspaceDefaultLinks.sync(rootPath: rootPath, manifest: manifest)
      for note in report.notes {
        logger.notice("workspace default link left as-is: \(String(describing: note), privacy: .private)")
      }
    } catch {
      logger.error("workspace default links not synced: \(String(describing: error), privacy: .private)")
    }
  }

  /// Reference rows of the Workspace at the source's canonical path.
  @MainActor
  static func referenceRows(in projectID: ProjectID, sourceGitRoot: String, context: Context) -> [WorktreeID] {
    let project = context.hierarchy.snapshot().projects.first { $0.id == projectID }
    return (project?.worktrees ?? [])
      .filter { $0.workspaceSlot?.role == .reference && canonical($0.path) == sourceGitRoot }
      .map(\.id)
  }

  /// Link names a new source must avoid: listed sources, and any entry
  /// already in the `default` directory (a non-link entry is user data).
  static func takenSourceNames(_ manifest: WorkspaceGroupsManifest, rootPath: String) -> Set<String> {
    var names = Set(manifest.projects.map(\.name))
    if let group = manifest.defaultGroup {
      let directory = (rootPath as NSString).appendingPathComponent(group.path)
      names.formUnion((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
    }
    return names
  }

  /// Resolves a source to its repository's main checkout without touching
  /// disk. A local path inside a linked worktree resolves to the source
  /// repository. A remote resolves to its clone destination, reused when it
  /// already holds a clone of that remote.
  static func resolveSource(
    _ source: WorkspaceSource, takenNames: Set<String>, context: Context
  ) async throws -> ResolvedSource {
    let sourceGitRoot: String
    var cloneFrom: String?
    var remoteURL: String?
    var derivedName: String
    switch source.location {
    case .local(let path):
      let expanded = canonical(path)
      guard isDirectory(expanded), let probe = try? await context.cli.inspectRepository(at: expanded)
      else { throw WorkspaceError.sourceNotRepository(path: expanded) }
      guard !probe.isBare else { throw WorkspaceError.bareRepository(path: canonical(probe.root)) }
      sourceGitRoot = canonical(probe.root)
      derivedName = (sourceGitRoot as NSString).lastPathComponent
    case .remote(let url, let cloneDestination):
      let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
      let expanded = canonical(cloneDestination)
      if FileManager.default.fileExists(atPath: expanded) {
        guard isDirectory(expanded),
          let probe = try? await context.cli.inspectRepository(at: expanded),
          !probe.isBare, canonical(probe.root) == expanded,
          let origin = await context.git.remoteURL(URL(fileURLWithPath: expanded, isDirectory: true), "origin"),
          remoteURLsMatch(origin, trimmedURL)
        else { throw WorkspaceError.cloneDestinationTaken(path: expanded, remoteURL: trimmedURL) }
      } else {
        cloneFrom = trimmedURL
      }
      sourceGitRoot = expanded
      remoteURL = trimmedURL
      derivedName =
        WorkspaceLayout.repositoryName(fromRemoteURL: trimmedURL) ?? (expanded as NSString).lastPathComponent
    }
    let name: String
    if let explicit = source.name?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
      guard WorkspaceManifest.isValidChildPath(explicit) else {
        throw WorkspaceError.invalidSourcePlan(reason: "\"\(explicit)\" is not a valid folder name")
      }
      guard !takenNames.contains(explicit) else { throw WorkspaceError.memberExists(name: explicit) }
      name = explicit
    } else {
      if !WorkspaceManifest.isValidChildPath(derivedName) {
        derivedName = "project"
      }
      var candidate = derivedName
      var suffix = 2
      while takenNames.contains(candidate) {
        candidate = "\(derivedName)-\(suffix)"
        suffix += 1
      }
      name = candidate
    }
    return ResolvedSource(name: name, sourceGitRoot: sourceGitRoot, remoteURL: remoteURL, cloneFrom: cloneFrom)
  }

  /// Clones a remote source that is not on disk yet; records it so a later
  /// failure deletes the clone.
  static func cloneIfNeeded(
    _ entry: ResolvedSource, ledger: inout WorkspaceMaterializationLedger, context: Context
  ) async throws {
    guard let remoteURL = entry.cloneFrom else { return }
    let destination = URL(fileURLWithPath: entry.sourceGitRoot, isDirectory: true)
    for try await _ in context.git.cloneStream(remoteURL, destination) {}
    // A cancelled consumer ends the clone stream quietly; do not read that
    // as a finished clone.
    try Task.checkCancellation()
    ledger.record(.clonedRepository(path: entry.sourceGitRoot))
  }
}
