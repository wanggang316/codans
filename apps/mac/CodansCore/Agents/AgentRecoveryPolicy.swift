import Foundation

/// Opt-in recovery for supported local agent sessions after a detected failure.
public nonisolated struct AgentRecoveryPolicy: Equatable, Codable, Sendable {
  public enum Action: String, Codable, CaseIterable, Sendable {
    case prompt
    case script
  }

  public var isEnabled: Bool
  public var action: Action
  public var prompt: String
  public var script: String
  public var delaySeconds: Int
  public var maxAttempts: Int
  public var additionalScriptReasons: Set<AgentFailure.Reason>

  public init(
    isEnabled: Bool = false,
    action: Action = .prompt,
    prompt: String = "Please retry the last failed request.",
    script: String = "",
    delaySeconds: Int = 30,
    maxAttempts: Int = 3,
    additionalScriptReasons: Set<AgentFailure.Reason> = []
  ) {
    self.isEnabled = isEnabled
    self.action = action
    self.prompt = prompt
    self.script = script
    self.delaySeconds = delaySeconds
    self.maxAttempts = maxAttempts
    self.additionalScriptReasons = additionalScriptReasons
  }

  private enum CodingKeys: String, CodingKey {
    case isEnabled, action, prompt, script, delaySeconds, maxAttempts, additionalScriptReasons
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
      action: try values.decodeIfPresent(Action.self, forKey: .action) ?? .prompt,
      prompt: try values.decodeIfPresent(String.self, forKey: .prompt) ?? "Please retry the last failed request.",
      script: try values.decodeIfPresent(String.self, forKey: .script) ?? "",
      delaySeconds: try values.decodeIfPresent(Int.self, forKey: .delaySeconds) ?? 30,
      maxAttempts: try values.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? 3,
      additionalScriptReasons: try values.decodeIfPresent(
        Set<AgentFailure.Reason>.self, forKey: .additionalScriptReasons) ?? []
    )
  }

  public func allows(_ failure: AgentFailure) -> Bool {
    guard isEnabled, isValid else { return false }
    if failure.reason == .transient || failure.reason == .rateLimited { return true }
    return action == .script && additionalScriptReasons.contains(failure.reason)
  }

  public func delay(for failure: AgentFailure) -> TimeInterval {
    let providerDelay = failure.reason == .rateLimited ? max(0, failure.retryAfterSeconds ?? 0) : 0
    return TimeInterval(max(delaySeconds, providerDelay))
  }

  /// Validate again at dispatch: settings can also be edited outside the app.
  public var isValid: Bool {
    let payload = action == .prompt ? prompt : script
    return (5...3600).contains(delaySeconds)
      && (1...10).contains(maxAttempts)
      && !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
