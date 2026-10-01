/// A rendered banner signature identifies text, not a failure occurrence.
public nonisolated struct ErrorBannerSignature: Hashable, Sendable {
  public let value: String
  public init(value: String) { self.value = value }
}

public nonisolated struct TerminalEvidence: Equatable, Sendable {
  public let currentErrorBanner: ErrorBannerSignature?
  public let visibleErrorBanners: Set<ErrorBannerSignature>

  public init(currentErrorBanner: ErrorBannerSignature? = nil, visibleErrorBanners: Set<ErrorBannerSignature> = []) {
    self.currentErrorBanner = currentErrorBanner
    self.visibleErrorBanners = visibleErrorBanners
  }
}

/// Factories guarantee that errors have current, visible evidence, and that
/// non-error results cannot carry a parallel current failure.
public nonisolated struct TerminalParseResult: Equatable, Sendable {
  public let state: AgentState
  public let inputAvailability: AgentInputAvailability
  public let evidence: TerminalEvidence

  private init(state: AgentState, inputAvailability: AgentInputAvailability, evidence: TerminalEvidence) {
    self.state = state
    self.inputAvailability = inputAvailability
    self.evidence = evidence
  }

  public static func unknown(
    inputAvailability: AgentInputAvailability = .unknown, visibleErrorBanners: Set<ErrorBannerSignature> = []
  ) -> Self {
    Self(
      state: .unknown, inputAvailability: inputAvailability, evidence: .init(visibleErrorBanners: visibleErrorBanners))
  }

  public static func idle(
    inputAvailability: AgentInputAvailability = .unknown, visibleErrorBanners: Set<ErrorBannerSignature> = []
  ) -> Self {
    Self(state: .idle, inputAvailability: inputAvailability, evidence: .init(visibleErrorBanners: visibleErrorBanners))
  }

  public static func working(
    inputAvailability: AgentInputAvailability = .unavailable, visibleErrorBanners: Set<ErrorBannerSignature> = []
  ) -> Self {
    Self(
      state: .working, inputAvailability: inputAvailability, evidence: .init(visibleErrorBanners: visibleErrorBanners))
  }

  public static func blocked(
    inputAvailability: AgentInputAvailability = .choice, visibleErrorBanners: Set<ErrorBannerSignature> = []
  ) -> Self {
    Self(
      state: .blocked, inputAvailability: inputAvailability, evidence: .init(visibleErrorBanners: visibleErrorBanners))
  }

  public static func error(
    failure: AgentFailure, banner: ErrorBannerSignature, inputAvailability: AgentInputAvailability = .unknown,
    visibleErrorBanners: Set<ErrorBannerSignature> = []
  ) -> Self {
    Self(
      state: .error(failure), inputAvailability: inputAvailability,
      evidence: .init(currentErrorBanner: banner, visibleErrorBanners: visibleErrorBanners.union([banner])))
  }
}
