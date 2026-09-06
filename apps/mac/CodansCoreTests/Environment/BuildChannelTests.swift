import Foundation
import Testing

@testable import CodansCore

/// Every channel-scoped spelling derives from `BuildChannel`, so these pin the
/// spellings themselves and the one compile-time decision behind them.
struct BuildChannelTests {
  @Test
  func currentFollowsTheBuildType() {
    #if DEBUG
      #expect(BuildChannel.current == .development)
    #else
      #expect(BuildChannel.current == .release)
    #endif
  }

  @Test
  func slugsAreTheOnDiskNames() {
    #expect(BuildChannel.development.slug == "codans-dev")
    #expect(BuildChannel.release.slug == "codans")
  }

  @Test
  func socketPathsAreSlugAndUID() {
    #expect(BuildChannel.development.socketPath(uid: 1234) == "/tmp/codans-dev-1234.sock")
    #expect(BuildChannel.release.socketPath(uid: 1234) == "/tmp/codans-1234.sock")
    #expect(BuildChannel.release.socketPathTemplate == "/tmp/codans-<uid>.sock")
  }

  @Test
  func otherIsAnInvolution() {
    for channel in BuildChannel.allCases {
      #expect(channel.other != channel)
      #expect(channel.other.other == channel)
    }
  }

  @Test
  func derivedSpellingsAgree() {
    // The consumers that used to carry their own `#if DEBUG`.
    #expect(AppDirectories.name == BuildChannel.current.slug)
    #expect(CLIInvocation.commandName == BuildChannel.current.slug)
  }
}
