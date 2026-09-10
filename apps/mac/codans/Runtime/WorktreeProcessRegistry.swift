import CodansCore
import Foundation

struct WorktreeProcessEntry: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable { case agent, run, command }

  var id: PaneID { paneID }
  let paneID: PaneID
  let projectID: ProjectID
  let worktreeID: WorktreeID
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

/// Session-only launch attribution. A catalog run-pane association alone never
/// creates an entry: every visible row requires a live foreground sample.
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

  var suspended: [PaneID: Suspended] = [:]
  var foregroundJobs: [PaneID: ForegroundJob] = [:]
  var entries: [PaneID: WorktreeProcessEntry] = [:]
  var launches: [PaneID: Launch] = [:]

  mutating func suspend(_ paneID: PaneID, now: Date) {
    if let entry = entries.removeValue(forKey: paneID) {
      suspended[paneID] = .init(entry: entry, expiresAt: now.addingTimeInterval(30))
    }
    if let pending = suspended[paneID], pending.expiresAt <= now {
      remove(paneID)
    } else if suspended[paneID] == nil,
      let launch = launches[paneID], now.timeIntervalSince(launch.requestedAt) >= 15
    {
      remove(paneID)
    }
  }

  mutating func retireIdle(_ paneID: PaneID, now: Date) {
    // A shell sample immediately retires an observed job. Before first
    // observation allow the shell a bounded window to start the command.
    let hadSuspended = suspended[paneID] != nil
    let hadEntry = entries[paneID] != nil || hadSuspended
    if hadSuspended { suspended.removeValue(forKey: paneID) }
    if entries[paneID] != nil { entries.removeValue(forKey: paneID) }
    if hadEntry
      || launches[paneID].map({ now.timeIntervalSince($0.requestedAt) >= 15 })
        == true
    {
      if launches[paneID] != nil { launches.removeValue(forKey: paneID) }
    }
  }

  mutating func remove(_ paneID: PaneID) {
    suspended.removeValue(forKey: paneID)
    foregroundJobs.removeValue(forKey: paneID)
    entries.removeValue(forKey: paneID)
    launches.removeValue(forKey: paneID)
  }
}

extension HierarchyManager {
  func recordProcessLaunch(
    paneID: PaneID, name: String, kind: WorktreeProcessEntry.Kind, now: Date = .now,
    requiresIdle: Bool = false
  ) {
    guard let (_, worktreeID, _) = addressOf(paneID: paneID),
      catalog.projects.flatMap(\.worktrees).contains(where: { $0.id == worktreeID && !$0.archived })
    else { return }
    if requiresIdle, let job = processRegistry.foregroundJobs[paneID],
      AgentKindPatterns.classify(foregroundJob: job) != nil
        || ForegroundJobClassifier.indicatesRunningCommand(job)
    {
      return
    }
    let observedIdle =
      processRegistry.foregroundJobs[paneID].map {
        !$0.isEmpty
          && AgentKindPatterns.classify(foregroundJob: $0) == nil
          && !ForegroundJobClassifier.indicatesRunningCommand($0)
      } ?? false
    processRegistry.remove(paneID)
    processRegistry.launches[paneID] = .init(
      name: name, kind: kind, requestedAt: now, requiresNewProcess: requiresIdle,
      observedIdle: observedIdle)
  }

  func processEntries(in worktreeID: WorktreeID) -> [WorktreeProcessEntry] {
    guard
      catalog.projects.flatMap(\.worktrees).contains(where: { $0.id == worktreeID && !$0.archived })
    else { return [] }
    return processRegistry.entries.values.filter {
      $0.worktreeID == worktreeID && catalog.pane($0.paneID) != nil
    }.sorted {
      if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
      return $0.paneID.raw.uuidString < $1.paneID.raw.uuidString
    }
  }

  func isCurrentProcess(_ entry: WorktreeProcessEntry) -> Bool {
    processEntries(in: entry.worktreeID).contains(entry)
  }

  func suspendProcessSample(paneID: PaneID, now: Date) {
    var registry = processRegistry
    registry.suspend(paneID, now: now)
    if registry != processRegistry { processRegistry = registry }
  }

  func updateProcessSample(paneID: PaneID, job: ForegroundJob, now: Date) {
    var registry = processRegistry
    defer {
      if registry != processRegistry { processRegistry = registry }
    }
    guard let (projectID, worktreeID, tabID) = addressOf(paneID: paneID),
      let worktree = catalog.projects.flatMap(\.worktrees).first(where: { $0.id == worktreeID }),
      !worktree.archived, let pane = catalog.pane(paneID)
    else {
      registry.remove(paneID)
      return
    }
    if let suspended = registry.suspended[paneID], suspended.expiresAt <= now {
      registry.remove(paneID)
    }
    if registry.foregroundJobs[paneID] != job { registry.foregroundJobs[paneID] = job }
    let agentKind = AgentKindPatterns.classify(foregroundJob: job)
    let running = agentKind != nil || ForegroundJobClassifier.indicatesRunningCommand(job)
    guard running else {
      registry.retireIdle(paneID, now: now)
      return
    }
    if registry.entries[paneID] == nil, registry.suspended[paneID] == nil,
      let pending = registry.launches[paneID],
      now.timeIntervalSince(pending.requestedAt) >= 15
    {
      registry.launches.removeValue(forKey: paneID)
    }
    let process =
      job.processes.first(where: {
        if let agentKind {
          return AgentKindPatterns.classify(
            foregroundJob: .init(processGroupID: job.processGroupID, processes: [$0])) == agentKind
        }
        return $0.pid == job.processGroupID
      }) ?? job.processes[0]
    if registry.launches[paneID]?.accepts(process) == false {
      registry.launches.removeValue(forKey: paneID)
    }
    let previous =
      registry.entries[paneID]
      ?? registry.suspended.removeValue(forKey: paneID)?.entry
    let sameProcess = previous?.pid == process.pid && previous?.startedAt == process.startedAt
    if previous != nil && !sameProcess {
      registry.launches.removeValue(forKey: paneID)
    }
    let currentLaunch = registry.launches[paneID]
    let name = currentLaunch?.name ?? agentKind?.displayName ?? process.processName
    let nextEntry = WorktreeProcessEntry(
      paneID: paneID, projectID: projectID, worktreeID: worktreeID, tabID: tabID,
      name: name, kind: agentKind != nil ? .agent : (currentLaunch?.kind ?? .command),
      pid: process.pid, startedAt: process.startedAt,
      observedAt: sameProcess ? (previous?.observedAt ?? now) : now,
      workingDirectory: pane.workingDirectory,
      processName: process.processName, agentKind: agentKind
    )
    if registry.entries[paneID] != nextEntry { registry.entries[paneID] = nextEntry }
  }
}
