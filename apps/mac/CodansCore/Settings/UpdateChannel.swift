import Foundation

/// Sparkle release channel. `stable` ships once a release is cut; `tip` opts the user into
/// pre-release tip-of-tree builds, mapping to the `tip` channel string in the appcast (handled
/// by an `SPUUpdaterDelegate.allowedChannels(for:)` adapter on the app side). Persisted in
/// `GeneralSettings.updateChannel` so the choice survives across launches and is the single
/// source of truth — Sparkle's own preferences are derived from this on bringup.
///
/// Channel only decides *which* appcast items match; the poll cadence is a separate
/// user-facing knob (`UpdateCheckInterval` on `GeneralSettings.updateCheckInterval`).
public nonisolated enum UpdateChannel: String, Equatable, Codable, Sendable, CaseIterable {
  case stable
  case tip

  /// Sparkle channel-string set returned by `allowedChannels(for:)`. An empty set means
  /// "only items with no `<sparkle:channel>` element" — the convention for stable.
  public var sparkleChannels: Set<String> {
    switch self {
    case .stable: return []
    case .tip: return ["tip"]
    }
  }
}
