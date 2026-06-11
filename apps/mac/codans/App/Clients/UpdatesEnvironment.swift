import Sparkle
import CodansCore

/// Shared owner of the app-wide `SPUStandardUpdaterController`. Sparkle
/// requires a single retained controller for the lifetime of the process —
/// it owns the periodic background-check timer + XPC services. Both the
/// TCA `UpdatesClient` (menu actions, settings push) and the Settings →
/// Updates pane (preference toggles) read through this namespace so they
/// share state instead of fighting over two separate controllers.
///
/// Channel selection is implemented via a custom delegate. Sparkle's
/// `allowedChannels(for:)` is the only documented hook for opting items
/// in/out of an appcast feed, so the delegate's `channel` is the writable
/// surface — the Settings pane mutates it indirectly through
/// `UpdatesClient.applyPreferences(...)`.
@MainActor
enum UpdatesEnvironment {
  static let delegate: ChannelUpdaterDelegate = ChannelUpdaterDelegate()

  static let controller: SPUStandardUpdaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: delegate,
    userDriverDelegate: nil
  )

  static var updater: SPUUpdater { controller.updater }
}

/// Bridges `UpdateChannel` into Sparkle's channel-filtering hook. The
/// delegate is referenced from the controller's init list so it must be
/// non-isolated (Sparkle calls `allowedChannels(for:)` from its own
/// thread); we hop to the main actor to read the current channel because
/// every writer also runs on `@MainActor`.
final class ChannelUpdaterDelegate: NSObject, SPUUpdaterDelegate, @unchecked Sendable {
  /// Mutated only on `@MainActor`; read can happen on any thread Sparkle
  /// schedules the delegate call from. `Atomic`-class wrapping would be
  /// overkill — `UpdateChannel` is a tiny value type, and the worst-case
  /// staleness is one extra background check after a flip.
  @MainActor private(set) var channel: UpdateChannel = .stable

  @MainActor
  func setChannel(_ channel: UpdateChannel) {
    self.channel = channel
  }

  nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    MainActor.assumeIsolated { channel.sparkleChannels }
  }
}
