import CodansCore
import Foundation
import Observation

/// Which coding-agent CLIs are actually present on this machine. The Agents
/// settings pane reads this to grey out profiles whose binary cannot be
/// found, so the list distinguishes "configured" from "runnable".
///
/// Resolution deliberately mirrors what a pane's shell would see rather than
/// what the GUI app inherits: a Finder-launched app gets launchd's minimal
/// `PATH`, which almost never contains Homebrew or a Node version manager.
/// One login-shell subprocess resolves the real `PATH`; every agent is then
/// probed against it with a filesystem check, so a machine with a dozen
/// agents still costs exactly one spawn.
@MainActor
@Observable
final class AgentInstallationStore {
  /// Agents whose executable resolved to a runnable file. Empty until the
  /// first scan completes — callers gate on `hasScanned` before treating an
  /// absence as "not installed".
  private(set) var installed: Set<AgentKind> = []
  /// `true` once a scan has produced a result. Until then the pane renders
  /// every row as enabled rather than flashing them all grey.
  private(set) var hasScanned = false

  @ObservationIgnored private let runner: any CommandRunner
  @ObservationIgnored private let fileManager: FileManager
  @ObservationIgnored private let environment: [String: String]
  @ObservationIgnored private let home: URL
  @ObservationIgnored private var scan: Task<Void, Never>?

  init(
    runner: any CommandRunner = FoundationCommandRunner(),
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) {
    self.runner = runner
    self.fileManager = fileManager
    self.environment = environment
    self.home = home
  }

  // Explicit (nonisolated) deinit so the compiler emits the standard
  // nonisolated tail instead of the isolated deinit Swift 6 synthesizes for
  // `@MainActor` classes — the store is `@State`-owned by a settings pane and
  // can be released inside a SwiftUI transaction flush, where an isolated
  // deinit's executor hop has been observed to abort in libmalloc (same class
  // of crash as `AgentStateOrderCoordinator`). `Task.cancel()` is nonisolated
  // and `Task?` is Sendable, so cancelling here is sound.
  deinit {
    scan?.cancel()
  }

  /// Runs a scan unless one has already completed. Safe to call from
  /// `.task` on every appear.
  func scanIfNeeded() async {
    guard !hasScanned else { return }
    await rescan()
  }

  /// Forces a fresh scan. Used by the pane's refresh affordance so an agent
  /// installed while the window was open shows up without a relaunch.
  func rescan() async {
    scan?.cancel()
    let task = Task { [runner, fileManager, environment, home] in
      let directories = await Self.searchDirectories(
        runner: runner, environment: environment, home: home)
      let found = Self.probe(directories: directories, fileManager: fileManager)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self.installed = found
        self.hasScanned = true
      }
    }
    scan = task
    await task.value
  }

  /// `true` when `kind`'s executable was found, or when no scan has completed
  /// yet — an unfinished probe must not misreport an installed agent as
  /// missing.
  func isInstalled(_ kind: AgentKind) -> Bool {
    hasScanned ? installed.contains(kind) : true
  }

  // MARK: - Resolution

  /// Directories searched for agent executables: the login shell's `PATH`
  /// plus the well-known per-user install roots that a `-l` shell misses when
  /// the user exports `PATH` from `.zshrc` (interactive-only) instead of
  /// `.zprofile`.
  private nonisolated static func searchDirectories(
    runner: any CommandRunner,
    environment: [String: String],
    home: URL
  ) async -> [String] {
    var directories = await loginShellPath(runner: runner, environment: environment)
    directories.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
    let userRoots = [
      ".local/bin", ".bun/bin", ".cargo/bin", ".volta/bin", ".deno/bin",
      "bin", ".npm-global/bin", "Library/pnpm",
    ]
    directories.append(
      contentsOf: userRoots.map {
        home.appendingPathComponent($0, isDirectory: true).path(percentEncoded: false)
      })

    var seen = Set<String>()
    return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  /// One login-shell spawn that prints the resolved `PATH`. Returns an empty
  /// list on any failure — the caller's static roots still give a usable
  /// answer, so a hung or exotic shell degrades instead of breaking the pane.
  private nonisolated static func loginShellPath(
    runner: any CommandRunner,
    environment: [String: String]
  ) async -> [String] {
    let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    let outcome = await runner.run(
      executable: URL(fileURLWithPath: shell),
      arguments: ["-l", "-c", "printf %s \"$PATH\""],
      env: environment,
      cwd: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
      timeout: .seconds(5),
      maxOutputBytes: 64 * 1024
    )
    guard case .exited(let code, let stdout, _, _) = outcome, code == 0,
      let raw = String(data: stdout, encoding: .utf8)
    else {
      return []
    }
    return raw.split(separator: ":").map(String.init)
  }

  /// Filesystem probe: an agent counts as installed when any search directory
  /// holds an executable file with its name.
  private nonisolated static func probe(
    directories: [String],
    fileManager: FileManager
  ) -> Set<AgentKind> {
    var found: Set<AgentKind> = []
    for descriptor in AgentCatalog.all {
      let isPresent = directories.contains { directory in
        let candidate = (directory as NSString).appendingPathComponent(descriptor.executable)
        return fileManager.isExecutableFile(atPath: candidate)
      }
      if isPresent {
        found.insert(descriptor.kind)
      }
    }
    return found
  }
}
