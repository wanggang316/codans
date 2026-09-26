import Foundation
import Testing

@testable import CodansCore

struct AgentRecoveryPolicyTests {
  @Test
  func legacySettingsKeepRecoveryDisabled() throws {
    for json in [#"{}"#, #"{"profiles": []}"#] {
      let settings = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))
      #expect(settings.recovery == AgentRecoveryPolicy())
      #expect(!settings.recovery.isEnabled)
    }
  }

  @Test
  func recoverySettingsRoundTripWithAnEmptyProfileList() throws {
    let policy = AgentRecoveryPolicy(
      isEnabled: true, action: .script, prompt: "Retry this task.",
      script: "./recover.sh", delaySeconds: 60, maxAttempts: 2
    )
    let settings = AgentSettings(profiles: [], recovery: policy)
    let decoded = try JSONDecoder().decode(
      AgentSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings)
  }

  @Test
  func validationChecksOnlyTheSelectedPayload() {
    var policy = AgentRecoveryPolicy()
    #expect(policy.isValid)
    policy.prompt = " \n\t"
    #expect(!policy.isValid)
    policy.action = .script
    policy.script = "./recover.sh"
    #expect(policy.isValid)
    policy.script = " \n\t"
    #expect(!policy.isValid)
  }

  @Test(arguments: [4, 3601, Int.min, Int.max])
  func rejectsInvalidDelays(_ delay: Int) {
    #expect(!AgentRecoveryPolicy(delaySeconds: delay).isValid)
  }

  @Test(arguments: [0, 11, Int.min, Int.max])
  func rejectsInvalidAttemptLimits(_ attempts: Int) {
    #expect(!AgentRecoveryPolicy(maxAttempts: attempts).isValid)
  }

  @Test(arguments: [5, 3600], [1, 10])
  func acceptsRangeBoundaries(_ delay: Int, _ attempts: Int) {
    #expect(AgentRecoveryPolicy(delaySeconds: delay, maxAttempts: attempts).isValid)
  }

  @Test
  func oldPolicyPayloadUsesConservativeFailureDefaults() throws {
    let data = Data(
      #"{"isEnabled":true,"action":"script","script":"./recover.sh","delaySeconds":30,"maxAttempts":3}"#.utf8)
    let policy = try JSONDecoder().decode(AgentRecoveryPolicy.self, from: data)
    #expect(policy.additionalScriptReasons.isEmpty)
    #expect(policy.allows(.init(reason: .transient, message: "timeout")))
    #expect(!policy.allows(.init(reason: .authentication, message: "401")))
  }

  @Test
  func permanentFailuresRequireExplicitScriptConfiguration() {
    var policy = AgentRecoveryPolicy(isEnabled: true, action: .script, script: "./repair.sh")
    let failure = AgentFailure(reason: .authentication, message: "401")
    #expect(!policy.allows(failure))
    policy.additionalScriptReasons.insert(.authentication)
    #expect(policy.allows(failure))
    policy.action = .prompt
    #expect(!policy.allows(failure))
    policy.isEnabled = false
    #expect(!policy.allows(.init(reason: .transient, message: "timeout")))
  }

  @Test
  func providerRateLimitDelayCannotBeShortened() {
    let policy = AgentRecoveryPolicy(isEnabled: true, delaySeconds: 30)
    #expect(policy.delay(for: .init(reason: .rateLimited, message: "429", retryAfterSeconds: 120)) == 120)
    #expect(policy.delay(for: .init(reason: .rateLimited, message: "429", retryAfterSeconds: -10)) == 30)
  }

  @Test
  func externallyEditedOutOfRangeSettingsRemainInvalid() throws {
    let policy = AgentRecoveryPolicy(isEnabled: true, delaySeconds: -1, maxAttempts: 100)
    let decoded = try JSONDecoder().decode(
      AgentRecoveryPolicy.self, from: JSONEncoder().encode(policy))
    #expect(!decoded.isValid)
  }
}
