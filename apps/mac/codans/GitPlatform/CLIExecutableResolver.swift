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
/// counting invocations. The production path uses `Self.livePathProbe()` which iterates
/// `$PATH` components and checks each for an executable file of the command's name.
actor CLIExecutableResolver {
  static let gh = CLIExecutableResolver(prober: livePathProbe(command: "gh"))
  static let glab = CLIExecutableResolver(prober: livePathProbe(command: "glab"))

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
      // Re-check cache: if `invalidate()` fired while the probe ran, don't clobber the
      // subsequent .empty state with a stale .resolved value. A missing CLI is not
      // cached, so a CLI installed while the app runs is found by the next call.
      if case .resolving = cache {
        cache = result.map(CacheState.resolved) ?? .empty
      }
      return result
    }
  }

  /// Clears the cache so the next `resolve()` re-probes. No-op when already empty.
  func invalidate() {
    cache = .empty
  }

  /// Live prober with three fallback layers, matching how a GUI-launched macOS app
  /// actually sees its environment:
  ///
  ///   1. `$PATH` walk — cheapest, but GUI apps inherit a stripped PATH
  ///      (`/usr/bin:/bin:/usr/sbin:/sbin`) that almost never contains Homebrew
  ///      or user-added directories, so this usually misses on a real user box.
  ///   2. Known Homebrew install paths (`/opt/homebrew/bin/<command>` on Apple Silicon,
  ///      `/usr/local/bin/<command>` on Intel). Covers the `brew install` case
  ///      without spawning a subprocess.
  ///   3. Login-shell `which <command>`. Loads the user's shell startup files
  ///      (`.zprofile`, `.bash_profile`, …), so any custom PATH entries
  ///      resolve. Final catch-all.
  ///
  /// `FileManager` is constructed inside the closure rather than captured, because
  /// `FileManager` is not `Sendable` in Swift 6 strict-concurrency mode.
  static func livePathProbe(
    command: String,
    env: any EnvironmentVariableProvider = LiveEnvironment()
  ) -> Prober {
    return {
      let fileManager = FileManager.default

      // 1. $PATH walk.
      if let pathValue = env.value(for: "PATH"), !pathValue.isEmpty {
        for component in pathValue.split(separator: ":", omittingEmptySubsequences: true) {
          let candidate = URL(fileURLWithPath: String(component))
            .appendingPathComponent(command)
          if fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
          }
        }
      }

      // 2. Hardcoded Homebrew paths — GUI-launched apps rarely inherit these in $PATH.
      for hardcoded in ["/opt/homebrew/bin/\(command)", "/usr/local/bin/\(command)"]
      where fileManager.isExecutableFile(atPath: hardcoded) {
        return URL(fileURLWithPath: hardcoded)
      }

      // 3. Login-shell fallback. Final catch-all for non-standard installs.
      return await Self.loginShellWhich(command)
    }
  }

  /// Runs `<user-shell> -l -c 'exec "$@"' -- /usr/bin/which <command>` so the user's
  /// shell rc is sourced and any custom `PATH` entries are visible. Returns the
  /// resolved absolute URL, or `nil` if the child exited non-zero / stdout was empty /
  /// `Process.run()` threw.
  ///
  /// `Process`/`waitUntilExit()` are synchronous-blocking; the call is detached onto a
  /// utility Task so Swift's cooperative pool isn't starved while the shell spins up.
  private static func loginShellWhich(_ command: String) async -> URL? {
    await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
      Task.detached(priority: .utility) {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellURL = URL(fileURLWithPath: shellPath)
        let exec =
          shellURL.lastPathComponent == "fish"
          ? "exec $argv"
          : "exec \"$@\""

        let process = Process()
        process.executableURL = shellURL
        process.arguments = ["-l", "-c", exec, "--", "/usr/bin/which", command]
        let stdoutPipe = Pipe.closeOnExec()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // A login shell's rc files can start daemons that inherit stdout.
        let stdoutCollector = PipeCollector(pipe: stdoutPipe)

        do {
          try process.run()
        } catch {
          try? stdoutPipe.fileHandleForWriting.close()
          _ = stdoutCollector.finishBlocking()
          cont.resume(returning: nil)
          return
        }
        process.waitUntilExit()
        let data = stdoutCollector.finishBlocking().data
        guard process.terminationStatus == 0,
          let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty
        else {
          cont.resume(returning: nil)
          return
        }
        cont.resume(returning: URL(fileURLWithPath: text))
      }
    }
  }
}
