import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The Clone Repository sheet: Cancel stops a running clone and leaves the
/// sheet open, and a failed clone shows a classified message with git's
/// output as the detail. git never runs; the CLI sits on a stub runner.
@MainActor
struct CloneRepoFeatureTests {
  private let remote = "https://github.com/o/r.git"
  private let destination = NSTemporaryDirectory() + "codans-clone-test-\(UUID().uuidString)/r"

  private func makeStore(runner: any CommandRunner) -> TestStoreOf<CloneRepoFeature> {
    TestStore(
      initialState: CloneRepoFeature.State(remoteURLDraft: remote, localPathDraft: destination)
    ) {
      CloneRepoFeature()
    } withDependencies: {
      $0[GitWorktreeCLI.self] = GitWorktreeCLI(runner: runner, parentEnvironment: [:])
    }
  }

  @Test
  func cancelDuringACloneStopsItAndNoResultArrivesAfterward() async {
    let runner = HangingCommandRunner()
    let store = makeStore(runner: runner)

    await store.send(.cloneButtonTapped) { $0.isCloning = true }
    await runner.waitUntilStarted()
    await store.send(.cancelButtonTapped) { $0.isCloning = false }
    // The cancelled runner reports a failure; the cancelled effect must drop
    // it, so the store receives nothing (TestStore fails on any action).
    await store.finish()
    #expect(await runner.wasCancelled)
  }

  @Test
  func cancelWhenNotCloningDismissesTheSheet() async {
    let store = makeStore(runner: RecordingCommandRunner())
    await store.send(.cancelButtonTapped)
    await store.receive(\.delegate.dismissed)
  }

  @Test
  func credentialFailureShowsTheNextStepAndKeepsGitOutputAsDetail() async {
    let stderr = "fatal: could not read Username for 'https://github.com': terminal prompts disabled\n"
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 128, stdout: Data(), stderr: Data(stderr.utf8), stdoutOverflow: false)
    ])
    let store = makeStore(runner: runner)
    let expected = CloneFailure(stderr: stderr, remoteURL: remote)

    await store.send(.cloneButtonTapped) { $0.isCloning = true }
    await store.receive(\.cloneFailed, expected) {
      $0.isCloning = false
      $0.errorMessage = expected.summary
      $0.errorDetail = expected.detail
    }
    #expect(expected.summary.contains("gh auth login"))
  }
}

/// A runner whose command never ends until the calling task is cancelled,
/// then reports `.timedOut` as the live runner does.
private actor HangingCommandRunner: CommandRunner {
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var wasCancelled = false

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func run(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration,
    maxOutputBytes: Int,
    launch: CommandLaunch
  ) async -> CommandOutcome {
    started = true
    for waiter in startWaiters { waiter.resume() }
    startWaiters = []
    try? await Task.sleep(for: .seconds(3600))
    wasCancelled = Task.isCancelled
    return .timedOut
  }
}
