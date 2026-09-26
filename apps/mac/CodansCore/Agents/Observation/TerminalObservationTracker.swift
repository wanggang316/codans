import Foundation

/// Per-instance acceptance and dismissal of terminal evidence. Captures advance
/// sequence; only accepted state changes or new banners advance stateRevision.
public nonisolated struct TerminalObservationTracker: Sendable {
  public let instanceID: AgentInstanceID
  public private(set) var lastObservation: AgentObservation?
  public private(set) var visibleErrorBanners: Set<ErrorBannerSignature> = []
  private var excludedErrorBanners: Set<ErrorBannerSignature>
  private var currentErrorBanner: ErrorBannerSignature?
  private var sequence: UInt64 = 0
  private var stateRevision: UInt64 = 0

  public init(instanceID: AgentInstanceID, excludedErrorBanners: Set<ErrorBannerSignature> = []) {
    self.instanceID = instanceID
    self.excludedErrorBanners = excludedErrorBanners
  }

  public mutating func accept(_ result: TerminalParseResult, observedAt: Date) -> AgentObservation {
    sequence &+= 1
    visibleErrorBanners = result.evidence.visibleErrorBanners
    excludedErrorBanners.formIntersection(visibleErrorBanners)
    if result.state == .working || result.state == .blocked {
      excludedErrorBanners.removeAll()
    }
    var acceptedState = result.state
    var acceptedBanner = result.evidence.currentErrorBanner
    if let banner = acceptedBanner, excludedErrorBanners.contains(banner) {
      if case .prompt = result.inputAvailability { acceptedState = .idle } else { acceptedState = .unknown }
      acceptedBanner = nil
    }
    if lastObservation?.state != acceptedState || currentErrorBanner != acceptedBanner {
      stateRevision &+= 1
    }
    currentErrorBanner = acceptedBanner
    let observation = AgentObservation(
      instanceID: instanceID, stateRevision: stateRevision, sequence: sequence,
      observedAt: observedAt, state: acceptedState, inputAvailability: result.inputAvailability)
    lastObservation = observation
    return observation
  }

  /// Called before external input reaches the terminal. Recovery-owned writes
  /// retain their current scope and do not call this dismissal hook.
  /// The last failure is invalid immediately, without manufacturing a new capture.
  public mutating func recordInput() {
    if let banner = currentErrorBanner { excludedErrorBanners.insert(banner) }
    currentErrorBanner = nil
    guard let previous = lastObservation else { return }
    if previous.state != .unknown { stateRevision &+= 1 }
    lastObservation = AgentObservation(
      instanceID: instanceID, stateRevision: stateRevision, sequence: sequence,
      observedAt: previous.observedAt, state: .unknown, inputAvailability: .unknown)
  }
}
