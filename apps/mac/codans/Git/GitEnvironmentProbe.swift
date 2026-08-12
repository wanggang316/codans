import ComposableArchitecture
import Foundation

/// One-shot `git --version` probe answering a single question: is `git` usable on this machine
/// at all?
///
/// Runs through the shared `CommandRunner` seam with `GitProcessEnv`'s environment — which
/// forces `LC_ALL=C.UTF-8`, pinning the child's locale so `GitEnvironmentStatus.classify` can
/// match git's English diagnostics deterministically regardless of the user's system language.
///
/// The result is cached for the process lifetime: an environment block is not something that
/// changes on its own, and the probe is on the sidebar's appear path. `refresh()` forces a
/// re-run, which is what the banner's Recheck button calls after the user has applied the
/// suggested fix.
actor GitEnvironmentProbe {
  private let gitExecutable: URL
  private let runner: any CommandRunner
  private var cached: GitEnvironmentStatus?
  /// Coalesces concurrent first-callers onto one subprocess instead of N.
  private var inFlight: Task<GitEnvironmentStatus, Never>?

  init(
    gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
    runner: any CommandRunner = FoundationCommandRunner()
  ) {
    self.gitExecutable = gitExecutable
    self.runner = runner
  }

  /// Cached status, probing once on first call.
  func status() async -> GitEnvironmentStatus {
    if let cached { return cached }
    if let inFlight { return await inFlight.value }
    let task = Task { await probe() }
    inFlight = task
    let result = await task.value
    cached = result
    inFlight = nil
    return result
  }

  /// Discards the cache and re-probes. Wired to the banner's Recheck button.
  func refresh() async -> GitEnvironmentStatus {
    cached = nil
    inFlight = nil
    return await status()
  }

  private func probe() async -> GitEnvironmentStatus {
    let outcome = await runner.run(
      executable: gitExecutable,
      arguments: ["--version"],
      env: GitProcessEnv.build(),
      // `--version` needs no repository; the home directory is the one path guaranteed to
      // exist and to be readable by the user running the app.
      cwd: FileManager.default.homeDirectoryForCurrentUser,
      timeout: .seconds(5),
      maxOutputBytes: 4096
    )
    return GitEnvironmentStatus.classify(outcome)
  }
}

// MARK: - Dependency injection

extension GitEnvironmentProbe: DependencyKey {
  /// Single shared instance so the cache is process-wide rather than per-call-site.
  static let liveValue = GitEnvironmentProbe()

  /// Tests that don't exercise the probe must not spawn `/usr/bin/git`, and must not depend on
  /// the CI machine's Xcode license state. The default test probe reports a healthy
  /// environment so the banner stays hidden; tests that care inject their own runner.
  ///
  /// A single-element `RecordingCommandRunner` replays that outcome indefinitely, which is
  /// what a cached-and-refreshable probe needs.
  static let testValue = GitEnvironmentProbe(
    runner: RecordingCommandRunner(
      outcomes: [
        .exited(
          code: 0,
          stdout: Data("git version 2.39.5 (Apple Git-154)\n".utf8),
          stderr: Data(),
          stdoutOverflow: false
        )
      ]
    )
  )
}

extension DependencyValues {
  var gitEnvironmentProbe: GitEnvironmentProbe {
    get { self[GitEnvironmentProbe.self] }
    set { self[GitEnvironmentProbe.self] = newValue }
  }
}
