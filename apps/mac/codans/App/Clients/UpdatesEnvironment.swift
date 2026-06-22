import Sparkle
import CodansCore
import Observation

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

  /// Observable mirror of "is a newer version advertised for the active
  /// channel?". Written by `ChannelUpdaterDelegate` after every appcast load,
  /// read by the Sidebar toolbar to show / hide the persistent update
  /// reminder. Derived purely from appcast-vs-current version comparison, so
  /// it is independent of Sparkle's "Skip This Version" state — the reminder
  /// keeps showing until the user actually installs the update.
  static let model = UpdatesModel()
}

/// Human-facing description of an advertised update newer than the running
/// build. Value type so it can hop the actor boundary out of the (non-isolated)
/// Sparkle delegate callback.
struct AvailableUpdate: Equatable, Sendable {
  /// `CFBundleShortVersionString` of the advertised item, e.g. `0.4.13`.
  var displayVersion: String
}

/// App-wide observable: non-nil when the loaded appcast offers a version newer
/// than the running build. The Sidebar reminder button observes this.
@MainActor
@Observable
final class UpdatesModel {
  var available: AvailableUpdate?
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

  /// Fires after every appcast download (manual or background), regardless of
  /// whether Sparkle decides to surface its modal — including for versions the
  /// user previously skipped. We recompute "is there a newer build for the
  /// active channel?" off the raw appcast and publish it to `UpdatesModel`,
  /// so the Sidebar reminder is driven by version facts rather than Sparkle's
  /// skip-aware presentation logic.
  nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
    // Snapshot to Sendable value types on Sparkle's callback thread —
    // SUAppcast / SUAppcastItem are non-Sendable reference types and must not
    // cross the actor hop below.
    let items: [AppcastItemSnapshot] = appcast.items.map { item in
      AppcastItemSnapshot(
        version: item.versionString,
        displayVersion: item.displayVersionString ?? item.versionString,
        channel: item.channel,
        osVersionOK: item.minimumOperatingSystemVersionIsOK,
        isDelta: item.isDeltaUpdate
      )
    }
    Task { @MainActor in
      UpdatesEnvironment.model.available = Self.newestUpdate(
        in: items, allowedChannels: channel.sparkleChannels
      )
    }
  }

  /// Pick the highest-versioned appcast item that is newer than the running
  /// build and visible on the active channel. Mirrors Sparkle's own
  /// `allowedChannels(for:)` visibility rule: unkeyed items reach everyone,
  /// channel-keyed items only reach users whose `allowedChannels` contains the
  /// key. Returns `nil` when the running build is already current.
  private static func newestUpdate(
    in items: [AppcastItemSnapshot],
    allowedChannels: Set<String>
  ) -> AvailableUpdate? {
    guard
      let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    else { return nil }
    let comparator = SUStandardVersionComparator()
    let newer = items.filter { item in
      guard item.osVersionOK, !item.isDelta else { return false }
      if let key = item.channel, !allowedChannels.contains(key) { return false }
      return comparator.compareVersion(current, toVersion: item.version) == .orderedAscending
    }
    let best = newer.max { lhs, rhs in
      comparator.compareVersion(lhs.version, toVersion: rhs.version) == .orderedAscending
    }
    return best.map { AvailableUpdate(displayVersion: $0.displayVersion) }
  }
}

/// Sendable projection of the appcast fields needed to decide whether a newer
/// build is available, captured off `SUAppcastItem` before hopping actors.
private struct AppcastItemSnapshot: Sendable {
  let version: String
  let displayVersion: String
  let channel: String?
  let osVersionOK: Bool
  let isDelta: Bool
}
