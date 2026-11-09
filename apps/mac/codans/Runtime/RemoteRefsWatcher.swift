import CodansCore
import ComposableArchitecture
import CoreServices
import Foundation

/// Per-repository FSEvents observer on remote-tracking refs. Fires
/// `events()` with the GitHub fetch unit id when `refs/remotes/` or
/// `packed-refs` changes under the repository's common git dir — which a
/// `git push` (also the one inside `gh pr create`) or a `git fetch` does,
/// from any process: an agent in a pane, a human in an external terminal.
///
/// The pane foreground-job signal misses an agent's own `git push`, because
/// the agent stays the foreground job; this watcher is the signal for that
/// case. Root-level churn in the common dir (`index`, `HEAD`, `FETCH_HEAD`,
/// objects) is filtered out, so per-file events are requested.
@MainActor
final class RemoteRefsWatcher {
  private let core: FSEventsTreeWatcher<ProjectID>

  init(debounceInterval: Duration = .milliseconds(500)) {
    core = FSEventsTreeWatcher(
      label: "codans.remote-refs-fswatch",
      debounceInterval: debounceInterval,
      fileEvents: true,
      accepts: Self.isRemoteRefPath)
  }

  /// `true` for a path that records a remote-tracking ref: a loose ref (or
  /// its `.lock`) under `refs/remotes/`, or the packed-refs file.
  nonisolated static func isRemoteRefPath(_ path: String) -> Bool {
    if path.contains("/refs/remotes/") { return true }
    let name = (path as NSString).lastPathComponent
    return name == "packed-refs" || name == "packed-refs.lock"
  }

  /// Single subscriber. RootFeature's `onLaunch` is the only caller.
  func events() -> AsyncStream<ProjectID> { core.events() }

  /// Sync the watched set: fetch unit id → repository root. Units whose
  /// root has no resolvable git dir are skipped. Units sharing a common
  /// git dir each get a stream, so each yields its own id.
  func setRepositories(_ repositories: [ProjectID: String]) {
    var roots: [ProjectID: String] = [:]
    for (id, root) in repositories {
      guard
        let commonDir = WorktreeHeadResolver.commonDirURL(for: URL(fileURLWithPath: root))
      else { continue }
      roots[id] = Self.realPath(commonDir)
    }
    core.setRoots(roots)
  }

  /// The fully resolved path. FSEvents reports real paths, and
  /// `resolvingSymlinksInPath` maps `/private/var/…` back to the `/var`
  /// symlink, so `realpath(3)` is used instead.
  nonisolated static func realPath(_ url: URL) -> String {
    let raw = url.path(percentEncoded: false)
    guard let resolved = realpath(raw, nil) else { return raw }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  func isWatching(_ id: ProjectID, path: String) -> Bool {
    core.isWatching(id, path: path)
  }

  /// Tear everything down. Called from the host app's `onQuit` path.
  func stopAll() { core.stopAll() }
}

extension RemoteRefsWatcher: DependencyKey {
  /// Unconfigured fallback until `CodansApp.bringUp` overrides it with the
  /// live instance: `setRepositories` is never called, so no stream attaches
  /// and `events()` finishes only when replaced.
  static var liveValue: RemoteRefsWatcher {
    MainActor.assumeIsolated { RemoteRefsWatcher() }
  }

  static var testValue: RemoteRefsWatcher { liveValue }
}

extension DependencyValues {
  var remoteRefsWatcher: RemoteRefsWatcher {
    get { self[RemoteRefsWatcher.self] }
    set { self[RemoteRefsWatcher.self] = newValue }
  }
}
