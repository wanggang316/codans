import XCTest

/// Walks the live terminal against the built-in demo Mac (`CODANS_DEMO`)
/// and saves a screenshot of each state for design review. Skipped unless
/// `CODANS_SHOTS` (passed as `TEST_RUNNER_CODANS_SHOTS`) names a host
/// directory; `CODANS_SHOTS_PREFIX` prefixes the file names, e.g.
/// `iphone-dark`.
final class TerminalScreenshotsUITests: XCTestCase {
  private var env: [String: String] { ProcessInfo.processInfo.environment }

  override func setUp() {
    continueAfterFailure = true
  }

  @MainActor
  func testTerminalStates() throws {
    guard let directory = env["CODANS_SHOTS"], !directory.isEmpty else {
      throw XCTSkip("set TEST_RUNNER_CODANS_SHOTS to record")
    }
    let prefix = env["CODANS_SHOTS_PREFIX"] ?? "shot"
    func shot(_ name: String) {
      let png = XCUIScreen.main.screenshot().pngRepresentation
      let url = URL(fileURLWithPath: directory).appendingPathComponent("\(prefix)-\(name).png")
      try? png.write(to: url)
    }

    let app = launch(["CODANS_DEMO_PANE": "claude"])
    let screen = app.descendants(matching: .any)["terminal-screen"].firstMatch
    XCTAssertTrue(screen.waitForExistence(timeout: 40), "terminal never appeared")
    sleep(1)
    shot("1-terminal")

    let isPad = UIDevice.current.userInterfaceIdiom == .pad
    if !isPad {
      // Keyboard up: tap the screen.
      screen.tap()
      sleep(2)
      shot("2-keyboard")
      let hide = app.buttons["Hide Keyboard"]
      if hide.exists { hide.tap() }
      sleep(1)
    }

    // Ctrl armed, then the shortcut panel.
    let ctrl = app.descendants(matching: .any)["key-ctrl"].firstMatch
    if ctrl.waitForExistence(timeout: 5) {
      ctrl.tap()
      sleep(1)
      shot("3-ctrl-armed")
      ctrl.tap()  // disarm
      ctrl.press(forDuration: 0.9)
      let panel = app.descendants(matching: .any)["shortcut-panel"].firstMatch
      XCTAssertTrue(panel.waitForExistence(timeout: 5), "shortcut panel never opened")
      sleep(1)
      shot("4-ctrl-panel")
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
      sleep(1)
    }

    let menu = app.descendants(matching: .any)["tab-menu"].firstMatch
    if menu.waitForExistence(timeout: 5) {
      menu.tap()
      sleep(1)
      shot("5-tab-menu")
      let close = app.buttons["Close Pane…"]
      if close.waitForExistence(timeout: 3) {
        close.tap()
        sleep(1)
        shot("6-close-confirmation")
        // A popover-style dialog has no Cancel button; tap outside it.
        let cancel = app.buttons["Cancel"]
        if cancel.exists {
          cancel.tap()
        } else {
          app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        }
        sleep(1)
      }
    }

    let compose = app.buttons["Compose"]
    if compose.waitForExistence(timeout: 3) {
      compose.tap()
      let field = app.descendants(matching: .any)["compose-field"].firstMatch
      // The first tap may only dismiss a popover still on screen.
      if !field.waitForExistence(timeout: 2) { compose.tap() }
      if field.waitForExistence(timeout: 3) {
        field.typeText("Refactor the key bar so modifiers\nlatch and lock")
      }
      sleep(1)
      shot("7-compose")
      let closeCompose = app.descendants(matching: .any)["compose-close"].firstMatch
      if closeCompose.exists { closeCompose.tap() }
    }

    app.terminate()
    let offline = launch(["CODANS_DEMO_PANE": "claude", "CODANS_DEMO_RECONNECT": "1"])
    let reconnecting = offline.descendants(matching: .any)["terminal-reconnecting"].firstMatch
    XCTAssertTrue(reconnecting.waitForExistence(timeout: 15), "reconnecting overlay never appeared")
    sleep(1)
    shot("8-reconnecting")

    offline.terminate()
    let notOpen = launch(["CODANS_DEMO_PANE": "shell", "CODANS_DEMO_NOT_OPEN": "1"])
    let shellScreen = notOpen.descendants(matching: .any)["terminal-screen"].firstMatch
    XCTAssertTrue(shellScreen.waitForExistence(timeout: 15))
    let esc = notOpen.descendants(matching: .any)["key-esc"].firstMatch
    if esc.waitForExistence(timeout: 5) { esc.tap() }
    _ = notOpen.descendants(matching: .any)["terminal-notice"].firstMatch.waitForExistence(timeout: 5)
    sleep(1)
    shot("9-not-open-on-mac")

    notOpen.terminate()
    let readOnly = launch(["CODANS_DEMO_PANE": "build", "CODANS_DEMO_READONLY": "1"])
    XCTAssertTrue(readOnly.descendants(matching: .any)["terminal-screen"].firstMatch.waitForExistence(timeout: 15))
    sleep(1)
    shot("10-read-only")

    readOnly.terminate()
    let exited = launch(["CODANS_DEMO_PANE": "shell", "CODANS_DEMO_EXITED": "1"])
    XCTAssertTrue(
      exited.descendants(matching: .any)["terminal-exited"].firstMatch.waitForExistence(timeout: 15),
      "exited banner never appeared")
    sleep(1)
    shot("11-exited")
  }

  @MainActor
  private func launch(_ extra: [String: String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment = ["CODANS_DEMO": "1"].merging(extra) { $1 }
    app.launch()
    return app
  }
}
