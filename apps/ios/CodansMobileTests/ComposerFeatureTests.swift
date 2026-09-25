import CodansIPC
import ComposableArchitecture
import Foundation
import Testing

@testable import CodansMobile

/// Starting an agent from the phone: profile list, launching into an
/// existing worktree, creating a worktree first, and failures keeping the
/// draft.
@MainActor
struct ComposerFeatureTests {
  @Test
  func profilesKeepOnlyEnabledInstalledOnesAndDropAVanishedSelection() async {
    let claude = Fixtures.profile("Claude")
    // "Not probed yet" is not "missing".
    let probing = Fixtures.profile("Probing", installed: nil)
    var initial = ComposerFeature.State()
    initial.profileID = UUID()
    let store = TestStore(initialState: initial) { ComposerFeature() }

    await store.send(
      .profilesLoaded([
        claude,
        Fixtures.profile("Off", enabled: false),
        Fixtures.profile("Missing", installed: false),
        probing,
      ])
    ) {
      $0.profiles = [claude, probing]
      $0.profileID = nil
    }
    #expect(store.state.profile?.name == "Claude")
  }

  @Test
  func sendingIntoAWorktreeLaunchesWithThePromptAndClearsTheDraft() async {
    let claude = Fixtures.profile("Claude")
    let launches = LockIsolated<[[String?]]>([])
    var initial = ComposerFeature.State()
    initial.profiles = [claude]
    initial.target = .worktree(projectID: "P", worktreeID: "W")
    initial.prompt = "  fix the login bug  "
    let store = TestStore(initialState: initial) {
      ComposerFeature()
    } withDependencies: {
      $0.remoteClient.launchAgent = { project, worktree, profile, prompt in
        launches.withValue { $0.append([project, worktree, profile, prompt]) }
        return "PANE"
      }
    }

    await store.send(.sendTapped) {
      $0.isSending = true
    }
    await store.receive(\.launched) {
      $0.isSending = false
      $0.prompt = ""
      $0.lastLaunch = ComposerFeature.Launch(worktreeID: "W", paneID: "PANE")
    }
    #expect(launches.value == [["P", "W", claude.id.uuidString, "fix the login bug"]])
  }

  @Test
  func newWorktreeIsCreatedFromThePromptThenBecomesTheTarget() async {
    let claude = Fixtures.profile("Claude")
    let created = LockIsolated<[String]>([])
    var initial = ComposerFeature.State()
    initial.profiles = [claude]
    initial.target = .newWorktree(projectID: "P")
    initial.prompt = "Add dark mode to Settings!"
    let store = TestStore(initialState: initial) {
      ComposerFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.remoteClient.createWorktree = { project, branch in
        created.withValue { $0.append("\(project):\(branch)") }
        return "NEW"
      }
      $0.remoteClient.launchAgent = { _, worktree, _, _ in
        #expect(worktree == "NEW")
        return nil
      }
    }

    await store.send(.sendTapped) {
      $0.isSending = true
    }
    await store.receive(\.launched) {
      $0.isSending = false
      $0.prompt = ""
      $0.lastLaunch = ComposerFeature.Launch(worktreeID: "NEW", paneID: nil)
      $0.target = .worktree(projectID: "P", worktreeID: "NEW")
    }
    #expect(created.value == ["P:agent/add-dark-mode-to"])
  }

  @Test
  func failureKeepsTheDraftAndShowsWhy() async {
    var initial = ComposerFeature.State()
    initial.profiles = [Fixtures.profile("Claude")]
    initial.target = .worktree(projectID: "P", worktreeID: "W")
    initial.prompt = "hello"
    let store = TestStore(initialState: initial) {
      ComposerFeature()
    } withDependencies: {
      $0.remoteClient.launchAgent = { _, _, _, _ in throw RemoteFailure(.forbidden, "Not allowed") }
    }

    await store.send(.sendTapped) {
      $0.isSending = true
    }
    await store.receive(\.sendFailed) {
      $0.isSending = false
      $0.errorMessage = "Not allowed"
    }
    #expect(store.state.prompt == "hello")
  }

  @Test
  func promptlessAgentStartsWithoutTheMessage() async {
    let bare = Fixtures.profile("Shell agent", prompt: false)
    let prompts = LockIsolated<[String?]>([])
    var initial = ComposerFeature.State()
    initial.profiles = [bare]
    initial.target = .worktree(projectID: "P", worktreeID: "W")
    initial.prompt = "ignored"
    let store = TestStore(initialState: initial) {
      ComposerFeature()
    } withDependencies: {
      $0.remoteClient.launchAgent = { _, _, _, prompt in
        prompts.withValue { $0.append(prompt) }
        return "PANE"
      }
    }
    store.exhaustivity = .off
    await store.send(.sendTapped)
    await store.receive(\.launched)
    #expect(prompts.value == [nil])
  }

  @Test
  func branchNamesComeFromTheTypedNameThePromptOrTheTime() {
    var state = ComposerFeature.State()
    let noon = DateComponents(
      calendar: .current, year: 2026, month: 9, day: 25, hour: 12, minute: 5
    ).date!
    #expect(state.resolvedBranch(now: noon) == "agent/20260925-1205")
    state.prompt = "修复登录"
    #expect(state.resolvedBranch(now: noon) == "agent/20260925-1205")
    state.prompt = "Fix the flaky login test, please"
    #expect(state.resolvedBranch(now: noon) == "agent/fix-the-flaky-login")
    state.branch = "  feature/x  "
    #expect(state.resolvedBranch(now: noon) == "feature/x")
  }
}
