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
  func externallyEditedOutOfRangeSettingsRemainInvalid() throws {
    let policy = AgentRecoveryPolicy(isEnabled: true, delaySeconds: -1, maxAttempts: 100)
    let decoded = try JSONDecoder().decode(
      AgentRecoveryPolicy.self, from: JSONEncoder().encode(policy))
    #expect(!decoded.isValid)
  }
}
