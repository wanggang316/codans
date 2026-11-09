import Foundation
import Testing

@testable import CodansCore

struct GitPlatformAvailabilityTests {
  @Test
  func unknownIsNotAvailable() {
    #expect(GitPlatformAvailability.unknown.isAvailable == false)
  }

  @Test
  func availableReportsTrue() {
    let a = GitPlatformAvailability.available(host: "github.com", user: "gump")
    #expect(a.isAvailable == true)
  }

  @Test
  func unavailableReportsFalse() {
    #expect(GitPlatformAvailability.unavailable(reason: "gh not installed").isAvailable == false)
  }

  @Test
  func notInstalledReportsFalse() {
    #expect(GitPlatformAvailability.notInstalled.isAvailable == false)
  }

  @Test
  func notLoggedInReportsFalse() {
    #expect(GitPlatformAvailability.notLoggedIn(host: nil).isAvailable == false)
  }

  @Test
  func loginCommandUsesTheCLIName() {
    #expect(GitPlatformKind.github.loginCommand == "gh auth login")
    #expect(GitPlatformKind.gitlab.loginCommand == "glab auth login")
    #expect(
      GitPlatformKind.gitlab.loginCommand(host: "gitlab.example.com")
        == "glab auth login --hostname gitlab.example.com")
  }

  @Test
  func installCommandUsesHomebrewAndTheCLIName() {
    #expect(GitPlatformKind.github.installCommand == "brew install gh")
    #expect(GitPlatformKind.gitlab.installCommand == "brew install glab")
  }

  @Test
  func equalityDiscriminatesCases() {
    #expect(GitPlatformAvailability.unknown == GitPlatformAvailability.unknown)
    #expect(
      GitPlatformAvailability.available(host: "github.com", user: "gump")
        == GitPlatformAvailability.available(host: "github.com", user: "gump")
    )
    #expect(
      GitPlatformAvailability.available(host: "github.com", user: "gump")
        != GitPlatformAvailability.available(host: "github.com", user: "other")
    )
    #expect(
      GitPlatformAvailability.unavailable(reason: "a") != GitPlatformAvailability.unavailable(reason: "b")
    )
  }
}
