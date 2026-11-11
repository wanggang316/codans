import CodansCore
import Foundation
import Observation

/// Which coding-agent CLIs this machine can actually run. The Agents settings
/// pane reads it to grey out profiles whose binary cannot be found, so the
/// list distinguishes "configured" from "runnable".
///
/// Resolution asks the user's login shell the same question a pane would:
/// the account's shell runs `command -v` over every known agent as an
/// interactive shell (`-i`), started through the shared login-shell launch
/// (`CommandLaunch.loginShell`). The launch gives it the account shell and
/// the login `PATH`, so a Finder-launched app with launchd's minimal `PATH`
/// still sees what the rc adds; `-i` loads the rc again in that shell, so
/// `command -v` also sees the aliases and functions a pane would, because
/// codans types the agent command into an interactive pane shell. One spawn
/// answers for every agent.
///
/// The result is advisory, not a gate. The shell codans probes and the shell
/// a pane ends up with can still differ (per-project environment, a version
/// manager that only activates on `cd`), so a false "missing" must never stop
/// the user launching an agent — it only dims the row. See `isInstalled`.
@MainActor
@Observable
final class AgentInstallationStore {
  /// Agents whose executable the shell could resolve. Empty until the first
  /// scan completes — callers gate on `hasScanned` before treating an
  /// absence as "not installed".
  private(set) var installed: Set<AgentKind> = []
  /// `true` once a scan has produced a result. Until then the pane renders
  /// every row as present rather than flashing them all grey.
  private(set) var hasScanned = false

  @ObservationIgnored private let runner: any CommandRunner
  @ObservationIgnored private let fileManager: FileManager
  @ObservationIgnored private let environment: [String: String]
  @ObservationIgnored private let home: URL
  @ObservationIgnored private let loginShell: @Sendable () -> LoginShell
  @ObservationIgnored private var scan: Task<Void, Never>?

  init(
    runner: any CommandRunner = FoundationCommandRunner(),
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
    loginShell: @escaping @Sendable () -> LoginShell = { LoginShell.current() }
  ) {
    self.runner = runner
    self.fileManager = fileManager
    self.environment = environment
    self.home = home
    self.loginShell = loginShell
  }

  // Explicit (nonisolated) deinit so the compiler emits the standard
  // nonisolated tail instead of the isolated deinit Swift 6 synthesizes for
  // `@MainActor` classes — an isolated deinit's executor hop has been
  // observed to abort in libmalloc when a store is released inside a SwiftUI
  // transaction flush (same class of crash as `AgentStateOrderCoordinator`).
  // `Task.cancel()` is nonisolated and `Task?` is Sendable, so cancelling
  // here is sound.
  deinit {
    scan?.cancel()
  }

  /// Runs a scan unless one has already completed. Safe to call from
  /// `.task` on every appear.
  func scanIfNeeded() async {
    guard !hasScanned else { return }
    await rescan()
  }

  /// Forces a fresh scan, so an agent installed while the app was running
  /// shows up without a relaunch.
  func rescan() async {
    scan?.cancel()
    let task = Task { [runner, fileManager, environment, home, loginShell] in
      var found = await Self.shellResolved(
        runner: runner, shell: loginShell(), environment: environment, home: home)
      if found == nil {
        // Shell unavailable / hung / exotic. Fall back to walking the
        // well-known install roots so the pane still says something useful.
        found = Self.walkKnownRoots(fileManager: fileManager, home: home)
      }
      guard !Task.isCancelled, let found else { return }
      await MainActor.run {
        self.installed = found
        self.hasScanned = true
      }
    }
    scan = task
    await task.value
  }

  /// Whether `kind` resolved. `true` while no scan has completed yet — an
  /// unfinished probe must not misreport an installed agent as missing.
  ///
  /// Callers use this to *dim*, never to disable: the probe can be wrong in
  /// the "missing" direction (see the type doc), and a user who knows their
  /// agent works must still be able to run it.
  func isInstalled(_ kind: AgentKind) -> Bool {
    hasScanned ? installed.contains(kind) : true
  }

  /// What a launch surface offers: the enabled profiles, minus any whose CLI
  /// the shell could not resolve. The New Agent dialog and the Hand Off
  /// panel both go through here, so one rule decides what "installed" hides.
  ///
  /// It fails open, because the probe is advisory and is wrong in the
  /// "missing" direction more often than the other (see the type doc):
  /// before a scan has answered, `isInstalled` reports everything present,
  /// and if filtering would empty a non-empty list every profile comes back.
  /// An empty list is far likelier to mean codans could not read the user's
  /// shell than that the machine has no agents on it, and hiding the last
  /// one would leave nothing to launch and no hint why.
  nonisolated static func offeredProfiles(
    enabled: [AgentProfile],
    isInstalled: (AgentKind) -> Bool
  ) -> [AgentProfile] {
    let runnable = enabled.filter { isInstalled($0.kind) }
    return runnable.isEmpty ? enabled : runnable
  }

  // MARK: - Resolution

  /// Batch `command -v` in an interactive account shell with the login
  /// shell's `PATH` — the closest
  /// approximation of what a pane will resolve. Returns `nil` (not an empty
  /// set) when the shell could not be asked, so the caller can tell "nothing
  /// installed" from "could not tell".
  private nonisolated static func shellResolved(
    runner: any CommandRunner,
    shell: LoginShell,
    environment: [String: String],
    home: URL
  ) async -> Set<AgentKind>? {
    let descriptors = AgentCatalog.all
    // Each answer echoes the executable back and tab-separates the result, so
    // parsing keys on the name rather than on line position. The interactive
    // rc writes to the same stdout (a banner, a version-manager notice), and a
    // one-line shift would map every agent onto its neighbour's answer.
    let script =
      descriptors
      .map { descriptor -> String in
        let name = ShellQuoting.quoted(descriptor.executable)
        return "printf '%s\\t%s\\n' \(name) \"$(command -v -- \(name) 2>/dev/null)\""
      }
      .joined(separator: "; ")
    let outcome = await runner.run(
      executable: shell.url,
      arguments: ["-i", "-c", script],
      env: environment,
      cwd: home,
      timeout: .seconds(10),
      maxOutputBytes: 256 * 1024,
      launch: .loginShell
    )
    // A non-zero exit is fine: every line we asked for is parsed by name.
    guard case .exited(_, let stdout, _, _) = outcome,
      let raw = String(data: stdout, encoding: .utf8)
    else {
      return nil
    }
    var resolved: [String: String] = [:]
    for line in raw.split(separator: "\n") {
      let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { continue }
      resolved[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces)
    }
    // No recognisable answers at all means the shell never ran our script
    // (rc file bailed, wrong shell) — report "could not tell" rather than
    // "nothing installed".
    guard !resolved.isEmpty else { return nil }
    var found: Set<AgentKind> = []
    for descriptor in descriptors
    where !(resolved[descriptor.executable] ?? "").isEmpty {
      found.insert(descriptor.kind)
    }
    return found
  }

  /// Fallback when the shell cannot be asked: look for each executable under
  /// the roots agents are conventionally installed into.
  private nonisolated static func walkKnownRoots(
    fileManager: FileManager,
    home: URL
  ) -> Set<AgentKind> {
    var directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    let userRoots = [
      ".local/bin", ".bun/bin", ".cargo/bin", ".volta/bin", ".deno/bin",
      "bin", ".npm-global/bin", "Library/pnpm", ".opencode/bin",
    ]
    directories.append(
      contentsOf: userRoots.map {
        home.appendingPathComponent($0, isDirectory: true).path(percentEncoded: false)
      })

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
