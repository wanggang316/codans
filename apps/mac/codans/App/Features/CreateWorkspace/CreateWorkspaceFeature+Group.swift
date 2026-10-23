import CodansCore
import ComposableArchitecture
import Foundation

// New Group mode: the members come from the Workspace's projects with the
// defaults ordinary worktree creation uses, each project's branches load for
// its base-ref menu, and creation streams progress per project.
extension CreateWorkspaceFeature {
  func membersLoaded(
    _ defaults: [MemberCreationOptions], agentProfiles: [AgentProfile], state: inout State
  ) -> Effect<Action> {
    state.isLoadingMembers = false
    state.agentProfiles = agentProfiles
    state.groupMembers = IdentifiedArray(
      defaults.map { WorkspaceGroupMemberDraft(options: $0) }, uniquingIDsWith: { first, _ in first })
    var effects = state.groupMembers.map { member -> Effect<Action> in
      loadRefs(id: member.id, gitRoot: member.options.sourceGitRoot)
    }
    for id in state.groupMembers.ids { state.groupMembers[id: id]?.refs = .loading }
    effects.append(edited(&state))
    return .merge(effects)
  }

  func reduceGroupMember(id: String, action: Action.GroupMemberAction, state: inout State) -> Effect<Action> {
    switch action {
    case .refsLoaded(let inventory):
      state.groupMembers[id: id]?.refs = .loaded(inventory)
      return .none
    case .refsFailed(let message):
      state.groupMembers[id: id]?.refs = .failed(message)
      return .none
    case .retryRefsTapped:
      guard let member = state.groupMembers[id: id] else { return .none }
      state.groupMembers[id: id]?.refs = .loading
      return loadRefs(id: id, gitRoot: member.options.sourceGitRoot)
    case .baseRefChanged, .fetchChanged, .copyIgnoredChanged, .copyUntrackedChanged, .agentChanged:
      guard !state.creation.isBusy, state.creation != .createdWithSetupFailures else { return .none }
      state.groupMembers[id: id]?.options.apply(action)
      return edited(&state)
    }
  }

  private func loadRefs(id: String, gitRoot: String) -> Effect<Action> {
    let client = gitWorktreeClient
    let repoRoot = URL(fileURLWithPath: gitRoot, isDirectory: true)
    return .run { send in
      do {
        async let refs = client.branchRefs(repoRoot)
        async let locals = client.localBranchNames(repoRoot)
        async let worktrees = (try? client.lsWorktrees(repoRoot)) ?? []
        async let auto = (try? client.defaultRemoteBranchRef(repoRoot)) ?? nil
        let inventory = RefInventory(
          branchRefs: try await refs, localBranchNames: try await locals, worktrees: await worktrees,
          defaultRemoteBranchRef: await auto, repoRoot: gitRoot)
        await send(.groupMember(id, .refsLoaded(inventory)))
      } catch {
        await send(.groupMember(id, .refsFailed("Couldn't list the branches: \(WorkspaceClient.describe(error))")))
      }
    }
    .cancellable(id: CancelID.refs(id), cancelInFlight: true)
  }

  // MARK: Creation

  func startGroupCreation(_ plan: WorkspaceGroupPlan, _ state: inout State) -> Effect<Action> {
    let token = uuid()
    state.creationToken = token
    for id in state.groupMembers.ids { state.groupMembers[id: id]?.progress = .pending }
    state.creation = .running(current: nil)
    let client = workspaceClient
    return .merge(
      .cancel(id: CancelID.preflight),
      .run { send in
        do {
          for try await event in await client.createGroupStream(plan, token) {
            await send(.creationEvent(event))
          }
        } catch {
          // Findings that appeared since the last check go under their
          // fields, as a live check would have shown them.
          if case .groupPreflightFailed(let preflight) = error as? WorkspaceError {
            await send(.preflightFinished(preflight))
          }
          await send(Self.failure(error))
        }
      }
      .cancellable(id: CancelID.creation, cancelInFlight: true)
    )
  }

  // swiftlint:disable:next cyclomatic_complexity
  func reduceGroupEvent(_ event: WorkspaceCreationEvent, state: inout State) -> Effect<Action> {
    func memberID(named name: String) -> String? {
      state.groupMembers.first { $0.name == name }?.id
    }
    switch event {
    case .memberStarted(let name, let phase):
      guard let id = memberID(named: name) else { return .none }
      state.groupMembers[id: id]?.progress = .running(phase, lastLine: nil)
      state.creation = .running(current: name)
    case .progressLine(let name, let line):
      guard let id = memberID(named: name) else { return .none }
      switch state.groupMembers[id: id]?.progress {
      case .running(let phase, _): state.groupMembers[id: id]?.progress = .running(phase, lastLine: line)
      case .settingUp: state.groupMembers[id: id]?.progress = .settingUp(lastLine: line)
      default: break
      }
    case .memberFinished(let name):
      guard let id = memberID(named: name) else { return .none }
      state.groupMembers[id: id]?.progress = .done
    case .memberFailed(let name, let message):
      guard let id = memberID(named: name) else { return .none }
      state.groupMembers[id: id]?.progress = .failed(message)
    case .manifestWritten:
      state.creation = .finalizing("Adding to the sidebar\u{2026}")
    case .setupStarted(let name):
      guard let id = memberID(named: name) else { return .none }
      state.groupMembers[id: id]?.progress = .settingUp(lastLine: nil)
      state.creation = .finalizing("Running the setup script of \(name)\u{2026}")
    case .setupFailed(let name, let reason):
      guard let id = memberID(named: name) else { return .none }
      state.groupMembers[id: id]?.progress = .setupFailed(reason)
    case .rollingBack:
      state.creation = .rollingBack
      for id in state.groupMembers.ids {
        if case .failed = state.groupMembers[id: id]?.progress { continue }
        state.groupMembers[id: id]?.progress = .rolledBack
      }
    case .rolledBack(let failures):
      state.creation = .rolledBack(failures: failures)
    case .groupCreated(let result):
      for id in state.groupMembers.ids where state.groupMembers[id: id]?.progress.isSettingUp == true {
        state.groupMembers[id: id]?.progress = .done
      }
      state.creation = result.setupFailures.isEmpty ? .idle : .createdWithSetupFailures
      return .send(.delegate(.groupCreated(result)))
    case .groupRegistered, .registered:
      break
    }
    return .none
  }
}

extension WorkspaceGroupMemberDraft.Progress {
  fileprivate var isSettingUp: Bool {
    if case .settingUp = self { return true }
    return false
  }
}

extension MemberCreationOptions {
  fileprivate mutating func apply(_ action: CreateWorkspaceFeature.Action.GroupMemberAction) {
    switch action {
    case .baseRefChanged(let ref): baseRef = ref
    case .fetchChanged(let value): fetch = value
    case .copyIgnoredChanged(let value): copyIgnored = value
    case .copyUntrackedChanged(let value): copyUntracked = value
    case .agentChanged(let profileID): agentProfileID = profileID
    case .retryRefsTapped, .refsLoaded, .refsFailed: break
    }
  }
}
