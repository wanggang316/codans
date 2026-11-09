import Foundation
import Testing

@testable import Codans

/// Covers the pure parts of the live opener: path resolution and the
/// file-or-directory choice. `open` itself is not run here — it would launch
/// a real editor from the test host.
@MainActor
struct GhosttyConfigOpenerClientTests {
  @Test
  func liveConfigURLHonorsXDGConfigHome() {
    let client = GhosttyConfigOpenerClient.live(
      environment: ["XDG_CONFIG_HOME": "/tmp/codans-tests/xdg"],
      homeDirectoryURL: URL(fileURLWithPath: "/tmp/codans-tests/home")
    )
    #expect(client.configURL().path == "/tmp/codans-tests/xdg/ghostty/config")
  }

  @Test
  func liveConfigURLDefaultsToHomeDotConfig() {
    let client = GhosttyConfigOpenerClient.live(
      environment: [:],
      homeDirectoryURL: URL(fileURLWithPath: "/tmp/codans-tests/home")
    )
    #expect(client.configURL().path == "/tmp/codans-tests/home/.config/ghostty/config")
  }

  @Test
  func openTargetIsFileWhenItExists() {
    let url = URL(fileURLWithPath: "/tmp/codans-tests/xdg/ghostty/config")
    #expect(GhosttyConfigOpenerClient.openTarget(for: url, fileExists: true) == .file(url))
  }

  @Test
  func openTargetIsDirectoryWhenFileIsMissing() {
    let url = URL(fileURLWithPath: "/tmp/codans-tests/xdg/ghostty/config")
    #expect(
      GhosttyConfigOpenerClient.openTarget(for: url, fileExists: false)
        == .directory(URL(fileURLWithPath: "/tmp/codans-tests/xdg/ghostty", isDirectory: true))
    )
  }
}
