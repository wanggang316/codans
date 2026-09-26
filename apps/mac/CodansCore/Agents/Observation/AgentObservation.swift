import Foundation

/// One pure observation of rendered agent output. Error evidence remains
/// separate from activity so callers can suppress old banners consistently.
public nonisolated struct AgentObservation: Equatable, Sendable {
  public typealias Activity = AgentObservedActivity
  public let activity: Activity
  public let errorFingerprint: String?
  /// Error banners visible anywhere in the supplied region, including lines
  /// outside the recent activity window. Used only to retain suppression.
  public let visibleErrorFingerprints: Set<String>

  public init(
    activity: Activity,
    errorFingerprint: String? = nil,
    visibleErrorFingerprints: Set<String> = []
  ) {
    self.activity = activity
    self.errorFingerprint = errorFingerprint
    self.visibleErrorFingerprints = visibleErrorFingerprints
  }
}
