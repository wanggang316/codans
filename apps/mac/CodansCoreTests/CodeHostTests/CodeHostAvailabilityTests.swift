import Foundation
import Testing

@testable import CodansCore

struct CodeHostAvailabilityTests {
  @Test
  func unknownIsNotAvailable() {
    #expect(CodeHostAvailability.unknown.isAvailable == false)
  }

  @Test
  func availableReportsTrue() {
    let a = CodeHostAvailability.available(host: "github.com", user: "gump")
    #expect(a.isAvailable == true)
  }

  @Test
  func unavailableReportsFalse() {
    #expect(CodeHostAvailability.unavailable(reason: "gh not installed").isAvailable == false)
  }

  @Test
  func equalityDiscriminatesCases() {
    #expect(CodeHostAvailability.unknown == CodeHostAvailability.unknown)
    #expect(
      CodeHostAvailability.available(host: "github.com", user: "gump")
        == CodeHostAvailability.available(host: "github.com", user: "gump")
    )
    #expect(
      CodeHostAvailability.available(host: "github.com", user: "gump")
        != CodeHostAvailability.available(host: "github.com", user: "other")
    )
    #expect(
      CodeHostAvailability.unavailable(reason: "a") != CodeHostAvailability.unavailable(reason: "b")
    )
  }
}
