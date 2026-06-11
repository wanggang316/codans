import Foundation
import Testing

@testable import CodansCore

struct GitHubAvailabilityTests {
  @Test
  func unknownIsNotAvailable() {
    #expect(GitHubAvailability.unknown.isAvailable == false)
  }

  @Test
  func availableReportsTrue() {
    let a = GitHubAvailability.available(host: "github.com", user: "gump")
    #expect(a.isAvailable == true)
  }

  @Test
  func unavailableReportsFalse() {
    #expect(GitHubAvailability.unavailable(reason: "gh not installed").isAvailable == false)
  }

  @Test
  func equalityDiscriminatesCases() {
    #expect(GitHubAvailability.unknown == GitHubAvailability.unknown)
    #expect(
      GitHubAvailability.available(host: "github.com", user: "gump")
        == GitHubAvailability.available(host: "github.com", user: "gump")
    )
    #expect(
      GitHubAvailability.available(host: "github.com", user: "gump")
        != GitHubAvailability.available(host: "github.com", user: "other")
    )
    #expect(
      GitHubAvailability.unavailable(reason: "a") != GitHubAvailability.unavailable(reason: "b")
    )
  }
}
