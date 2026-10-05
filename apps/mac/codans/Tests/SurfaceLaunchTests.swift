import Testing

@testable import Codans

/// Pins how each launch shape maps onto `ghostty_surface_config_s`.
struct SurfaceLaunchTests {
  @Test
  func interactiveLeavesTheShellToLibghosttyAndKeepsIntegration() {
    let launch = SurfaceLaunch.interactive(wrapper: ["/Apps/zmx", "attach", "abc"])
    #expect(launch.command == nil)
    #expect(launch.wrapper == ["/Apps/zmx", "attach", "abc"])
    #expect(!launch.disablesShellIntegration)
  }

  @Test
  func commandRunsAsIsWithIntegrationOff() {
    let launch = SurfaceLaunch.command("'/Apps/zmx' attach 'abc' /bin/sh -c 'loop'")
    #expect(launch.command == "'/Apps/zmx' attach 'abc' /bin/sh -c 'loop'")
    #expect(launch.wrapper.isEmpty)
    #expect(launch.disablesShellIntegration)
  }

  @Test
  func bothShapesWaitAfterTheChildExits() {
    // Without a `command` libghostty would not turn this on by itself, and an
    // exiting shell would close the surface before the pane's exit handling.
    #expect(SurfaceLaunch.interactive(wrapper: ["zmx"]).waitsAfterCommand)
    #expect(SurfaceLaunch.command("x").waitsAfterCommand)
  }
}
