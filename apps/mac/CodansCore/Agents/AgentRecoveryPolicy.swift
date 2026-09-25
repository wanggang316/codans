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

  public init(
    isEnabled: Bool = false,
    action: Action = .prompt,
    prompt: String = "Please retry the last failed request.",
    script: String = "",
    delaySeconds: Int = 30,
    maxAttempts: Int = 3
  ) {
    self.isEnabled = isEnabled
    self.action = action
    self.prompt = prompt
    self.script = script
    self.delaySeconds = delaySeconds
    self.maxAttempts = maxAttempts
  }

  /// Validate again at dispatch: settings can also be edited outside the app.
  public var isValid: Bool {
    let payload = action == .prompt ? prompt : script
    return (5...3600).contains(delaySeconds)
      && (1...10).contains(maxAttempts)
      && !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
