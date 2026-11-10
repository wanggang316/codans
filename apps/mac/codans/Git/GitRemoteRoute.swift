import CodansCore
import Foundation

/// The one source of Remote Project routing for every live git client.
///
/// `GitServiceClient.liveValue` and `GitWorktreeClient.liveValue` both resolve
/// hosts through `shared`, so a reader outside the main window's root store
/// (the Settings window store, or a view that reads `@Dependency` directly)
/// gets a routed client, never a purely local one. The resolver is bound late
/// because the catalog that owns the routing exists only after bring-up; until
/// it is bound, every location resolves to This Mac.
nonisolated final class GitRemoteRoute: @unchecked Sendable {
  typealias Resolver = @Sendable (URL) async -> RemoteHost?

  static let shared = GitRemoteRoute()

  private let lock = NSLock()
  private var resolver: Resolver?

  /// Installs the resolver. A later call replaces the earlier one.
  func bind(_ resolver: Resolver?) {
    lock.withLock { self.resolver = resolver }
  }

  /// The Host that runs a git call on `url`, or `nil` for This Mac.
  func remoteHost(for url: URL) async -> RemoteHost? {
    let resolver = lock.withLock { self.resolver }
    return await resolver?(url)
  }
}
