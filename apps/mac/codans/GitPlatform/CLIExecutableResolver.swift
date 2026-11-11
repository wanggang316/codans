import Foundation

/// Abstraction over environment-variable lookup. `LiveEnvironment` reads
/// `ProcessInfo.processInfo.environment`; tests inject a fake to control `$PATH` without
/// touching the real shell.
nonisolated protocol EnvironmentVariableProvider: Sendable {
  func value(for key: String) -> String?
}

nonisolated struct LiveEnvironment: EnvironmentVariableProvider {
  func value(for key: String) -> String? {
    ProcessInfo.processInfo.environment[key]
  }
}

/// Resolves the absolute path of a Git Platform CLI (`gh`, `glab`) and caches it. A missing
/// CLI is not cached: each call probes again until the CLI is found.
///
/// Concurrent callers share a single resolution via a single-flight `Task`: the first
/// `resolve()` starts the probe, subsequent callers `await` the in-flight task. Subsequent
/// calls after resolution return the cached `URL?` without any filesystem activity.
///
/// `invalidate()` clears the cache so the next `resolve()` re-probes — used by the Settings
/// pane's "Re-check" button and when a `gh` / `glab` command finishes in a pane.
///
/// The prober is injected at init time so tests can assert single-flight behaviour by
/// counting invocations. The production path is `Self.livePathProbe()`; each Git Platform
/// implementation defines its shared resolver (`.gh`, `.glab`) with the environment its
/// CLI runs with.
actor CLIExecutableResolver {
  typealias Prober = @Sendable () async -> URL?

  private enum CacheState {
    case empty
    case resolving(Task<URL?, Never>)
    case resolved(URL)
  }

  private let prober: Prober
  private var cache: CacheState = .empty

  init(prober: @escaping Prober) {
    self.prober = prober
  }

  /// Returns the cached executable path, resolving on first call. Concurrent callers share the
  /// resolution task so the prober runs at most once per cache generation.
  func resolve() async -> URL? {
    switch cache {
    case .resolved(let url):
      return url
    case .resolving(let task):
      return await task.value
    case .empty:
      let prober = self.prober
      let task = Task<URL?, Never> { await prober() }
      cache = .resolving(task)
      let result = await task.value
      // Write the result only when this probe still owns the cache. After `invalidate()`
      // the cache is empty or owned by a newer probe; a stale path must not replace
      // either. A missing CLI is not cached, so a CLI installed while the app runs is
      // found by the next call.
      if case .resolving(let current) = cache, current == task {
        cache = result.map(CacheState.resolved) ?? .empty
      }
      return result
    }
  }

  /// Clears the cache so the next `resolve()` re-probes. No-op when already empty.
  func invalidate() {
    cache = .empty
  }

  /// Live prober. The login shell decides first, so the path is the one the background
  /// commands that run the CLI would pick:
  ///
  ///   1. `/usr/bin/which <command>` started through the user's login shell
  ///      (`CommandLaunch.loginShell`) with `launchEnvironment`, the environment the CLI
  ///      itself runs with: the same shell, rc inputs, and `PATH`.
  ///   2. `$PATH` walk of the app's environment, when the login shell cannot answer
  ///      (no such CLI on its `PATH`, a broken rc, a timeout).
  ///   3. Known Homebrew install paths (`/opt/homebrew/bin/<command>` on Apple Silicon,
  ///      `/usr/local/bin/<command>` on Intel).
  ///
  /// `FileManager` is constructed inside the closure rather than captured, because
  /// `FileManager` is not `Sendable` in Swift 6 strict-concurrency mode.
  static func livePathProbe(
    command: String,
    launchEnvironment: @escaping @Sendable () -> [String: String],
    env: any EnvironmentVariableProvider = LiveEnvironment(),
    runner: any CommandRunner = FoundationCommandRunner(),
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> Prober {
    return {
      // 1. Login shell.
      if let found = await loginShellWhich(command, env: launchEnvironment(), runner: runner, home: home) {
        return found
      }

      let fileManager = FileManager.default

      // 2. $PATH walk.
      if let pathValue = env.value(for: "PATH"), !pathValue.isEmpty {
        for component in pathValue.split(separator: ":", omittingEmptySubsequences: true) {
          let candidate = URL(fileURLWithPath: String(component))
            .appendingPathComponent(command)
          if fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
          }
        }
      }

      // 3. Hardcoded Homebrew paths.
      for hardcoded in ["/opt/homebrew/bin/\(command)", "/usr/local/bin/\(command)"]
      where fileManager.isExecutableFile(atPath: hardcoded) {
        return URL(fileURLWithPath: hardcoded)
      }
      return nil
    }
  }

  /// Runs `/usr/bin/which <command>` with the login shell's `PATH`. Returns the
  /// resolved absolute URL, or `nil` when `which` fails or prints nothing. The
  /// shared launch keeps rc output (a banner) out of stdout.
  static func loginShellWhich(
    _ command: String, env: [String: String], runner: any CommandRunner, home: URL
  ) async -> URL? {
    // `HOME` locates the rc.
    var env = env
    if env["HOME"] == nil { env["HOME"] = home.path }
    let outcome = await runner.run(
      executable: URL(fileURLWithPath: "/usr/bin/which"),
      arguments: [command],
      env: env,
      cwd: home,
      timeout: .seconds(10),
      maxOutputBytes: 64 * 1024,
      launch: .loginShell
    )
    guard case .exited(0, let stdout, _, _) = outcome,
      let text = String(data: stdout, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      text.hasPrefix("/")
    else {
      return nil
    }
    return URL(fileURLWithPath: text)
  }
}
