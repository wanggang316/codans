import CodansCore
import Foundation

struct WorktreeProcessEntry: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable { case agent, run, command }

  var id: ContentID { contentID }
  let contentID: ContentID
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let paneID: PaneID
  let tabID: TabID
  let name: String
  let kind: Kind
  let pid: Int32
  let startedAt: Date?
  let observedAt: Date
  let workingDirectory: String
  var processName: String = ""
  var agentKind: AgentKind?
}

/// Session-only launch attribution. A catalog run-Content association alone
/// never creates an entry: every visible row requires a live foreground
/// sample.
struct WorktreeProcessRegistry: Equatable {
  struct Launch: Equatable {
    let name: String
    let kind: WorktreeProcessEntry.Kind
    let requestedAt: Date
    let requiresNewProcess: Bool
    let observedIdle: Bool

    func accepts(_ process: ForegroundProcess) -> Bool {
      guard requiresNewProcess else { return true }
      guard let birth = process.startedAt else { return observedIdle }
      return birth >= requestedAt
    }

  }

  struct Suspended: Equatable {
    let entry: WorktreeProcessEntry
    let expiresAt: Date
  }

  var suspended: [ContentID: Suspended] = [:]
  var foregroundJobs: [ContentID: ForegroundJob] = [:]
  var entries: [ContentID: WorktreeProcessEntry] = [:]
  var launches: [ContentID: Launch] = [:]

  mutating func suspend(_ contentID: ContentID, now: Date) {
    if let entry = entries.removeValue(forKey: contentID) {
      suspended[contentID] = .init(entry: entry, expiresAt: now.addingTimeInterval(30))
    }
    if let pending = suspended[contentID], pending.expiresAt <= now {
      remove(contentID)
    } else if suspended[contentID] == nil,
      let launch = launches[contentID], now.timeIntervalSince(launch.requestedAt) >= 15
    {
      remove(contentID)
    }
  }

  mutating func retireIdle(_ contentID: ContentID, now: Date) {
    // A shell sample immediately retires an observed job. Before first
    // observation allow the shell a bounded window to start the command.
    let hadSuspended = suspended[contentID] != nil
    let hadEntry = entries[contentID] != nil || hadSuspended
    if hadSuspended { suspended.removeValue(forKey: contentID) }
    if entries[contentID] != nil { entries.removeValue(forKey: contentID) }
    if hadEntry
      || launches[contentID].map({ now.timeIntervalSince($0.requestedAt) >= 15 })
        == true
    {
      if launches[contentID] != nil { launches.removeValue(forKey: contentID) }
    }
  }

  mutating func remove(_ contentID: ContentID) {
    suspended.removeValue(forKey: contentID)
    foregroundJobs.removeValue(forKey: contentID)
    entries.removeValue(forKey: contentID)
    launches.removeValue(forKey: contentID)
  }
}

extension HierarchyManager {
  func recordProcessLaunch(
    contentID: ContentID, name: String, kind: WorktreeProcessEntry.Kind, now: Date = .now,
    requiresIdle: Bool = false
  ) {
    guard let address = catalog.address(forContent: contentID),
      catalog.projects.flatMap(\.worktrees).contains(where: { $0.id == address.worktreeID && !$0.archived })
    else { return }
    if requiresIdle, let job = processRegistry.foregroundJobs[contentID],
      AgentKindPatterns.classify(foregroundJob: job) != nil
        || ForegroundJobClassifier.indicatesRunningCommand(job)
    {
      return
    }
    let observedIdle =
      processRegistry.foregroundJobs[contentID].map {
        !$0.isEmpty
          && AgentKindPatterns.classify(foregroundJob: $0) == nil
          && !ForegroundJobClassifier.indicatesRunningCommand($0)
      } ?? false
    processRegistry.remove(contentID)
    processRegistry.launches[contentID] = .init(
      name: name, kind: kind, requestedAt: now, requiresNewProcess: requiresIdle,
      observedIdle: observedIdle)
  }

  func processEntries(in worktreeID: WorktreeID) -> [WorktreeProcessEntry] {
    guard
      catalog.projects.flatMap(\.worktrees).contains(where: { $0.id == worktreeID && !$0.archived })
    else { return [] }
    return processRegistry.entries.values.filter {
      $0.worktreeID == worktreeID && catalog.content($0.contentID) != nil
    }.sorted {
      if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
      return $0.contentID.raw.uuidString < $1.contentID.raw.uuidString
    }
  }

  /// The process a Tab shows in its hover card: its one Content's process.
  func processEntry(inTab tabID: TabID) -> WorktreeProcessEntry? {
    guard let address = catalog.address(forTab: tabID) else { return nil }
    return processEntries(in: address.worktreeID).first { $0.contentID == address.contentID }
  }

  func isCurrentProcess(_ entry: WorktreeProcessEntry) -> Bool {
    processEntries(in: entry.worktreeID).contains(entry)
  }

  func suspendProcessSample(contentID: ContentID, now: Date) {
    var registry = processRegistry
    registry.suspend(contentID, now: now)
    if registry != processRegistry { processRegistry = registry }
  }

  func updateProcessSample(contentID: ContentID, job: ForegroundJob, now: Date) {
    var registry = processRegistry
    defer {
      if registry != processRegistry { processRegistry = registry }
    }
    guard let address = catalog.address(forContent: contentID),
      let worktree = catalog.projects.flatMap(\.worktrees).first(where: { $0.id == address.worktreeID }),
      !worktree.archived, let state = catalog.content(contentID)?.terminal
    else {
      registry.remove(contentID)
      return
    }
    if let suspended = registry.suspended[contentID], suspended.expiresAt <= now {
      registry.remove(contentID)
    }
    if registry.foregroundJobs[contentID] != job { registry.foregroundJobs[contentID] = job }
    let agentKind = AgentKindPatterns.classify(foregroundJob: job)
    let running = agentKind != nil || ForegroundJobClassifier.indicatesRunningCommand(job)
    guard running else {
      registry.retireIdle(contentID, now: now)
      return
    }
    if registry.entries[contentID] == nil, registry.suspended[contentID] == nil,
      let pending = registry.launches[contentID],
      now.timeIntervalSince(pending.requestedAt) >= 15
    {
      registry.launches.removeValue(forKey: contentID)
    }
    let process =
      job.processes.first(where: {
        if let agentKind {
          return AgentKindPatterns.classify(
            foregroundJob: .init(processGroupID: job.processGroupID, processes: [$0])) == agentKind
        }
        return $0.pid == job.processGroupID
      }) ?? job.processes[0]
    if registry.launches[contentID]?.accepts(process) == false {
      registry.launches.removeValue(forKey: contentID)
    }
    let previous =
      registry.entries[contentID]
      ?? registry.suspended.removeValue(forKey: contentID)?.entry
    let sameProcess = previous?.pid == process.pid && previous?.startedAt == process.startedAt
    if previous != nil && !sameProcess {
      registry.launches.removeValue(forKey: contentID)
    }
    let currentLaunch = registry.launches[contentID]
    let name = currentLaunch?.name ?? agentKind?.displayName ?? process.processName
    let nextEntry = WorktreeProcessEntry(
      contentID: contentID, projectID: address.projectID, worktreeID: address.worktreeID,
      paneID: address.paneID, tabID: address.tabID,
      name: name, kind: agentKind != nil ? .agent : (currentLaunch?.kind ?? .command),
      pid: process.pid, startedAt: process.startedAt,
      observedAt: sameProcess ? (previous?.observedAt ?? now) : now,
      workingDirectory: state.workingDirectory,
      processName: process.processName, agentKind: agentKind
    )
    if registry.entries[contentID] != nextEntry { registry.entries[contentID] = nextEntry }
  }
}
