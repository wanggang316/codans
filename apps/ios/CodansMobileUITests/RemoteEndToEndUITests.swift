import XCTest

/// End to end against a live Mac gateway: open a pairing link, confirm,
/// browse to a pane, read it, and send a line into it. Driven by
/// `docs/user-tests/ios-companion/harness.sh`, which starts an isolated Mac
/// instance and passes its values through `TEST_RUNNER_`-prefixed
/// environment variables; without them the test is skipped, so a plain
/// `make test` never needs a Mac.
///
/// - `CODANS_E2E_PAIRING_CODE`: a `codans-pair:` code issued by the Mac.
/// - `CODANS_E2E_PROJECT`: name of the project whose first pane to open.
/// - `CODANS_E2E_INPUT`: line to send; omitted for a view-only device.
/// - `CODANS_E2E_COMPOSER_PROMPT`: first message for the composer test.
/// - `CODANS_E2E_SHOTS`: host directory for step screenshots (optional).
final class RemoteEndToEndUITests: XCTestCase {
  private var env: [String: String] { ProcessInfo.processInfo.environment }

  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testPairBrowseReadAndSend() throws {
    let app = XCUIApplication()
    let worktreeRow = try pairAndOpenWorkspace(app)
    worktreeRow.tap()

    // A worktree opens straight onto its terminal: the pane last viewed
    // there, else the Mac's focused pane.
    let screen = app.descendants(matching: .any)["terminal-screen"].firstMatch
    if !screen.waitForExistence(timeout: 5), worktreeRow.isHittable {
      worktreeRow.tap()  // a late hierarchy update can still swallow the first tap
    }
    XCTAssertTrue(screen.waitForExistence(timeout: 10), "worktree never opened a terminal")

    // The screen fills from the pane's stream; an empty screen means the
    // phone shows a blank terminal.
    let text = app.descendants(matching: .any)["terminal-text"].firstMatch
    XCTAssertTrue(text.waitForExistence(timeout: 10), "terminal never rendered")
    expectation(for: NSPredicate(format: "value MATCHES %@", "(?s).*\\S.*"), evaluatedWith: text)
    waitForExpectations(timeout: 10)
    shot("3-terminal-open")

    let keyBar = app.descendants(matching: .any)["terminal-key-bar"].firstMatch
    guard let line = env["CODANS_E2E_INPUT"], !line.isEmpty else {
      // View-only device: the key bar must never appear.
      XCTAssertFalse(keyBar.waitForExistence(timeout: 3), "view-only device shows the key bar")
      shot("4-terminal-readonly")
      return
    }
    XCTAssertTrue(keyBar.waitForExistence(timeout: 10), "interactive device has no key bar")
    screen.tap()
    app.typeText(line + "\n")

    // The Mac's pane echoes the line back over the stream.
    expectation(for: NSPredicate(format: "value CONTAINS %@", line), evaluatedWith: text)
    waitForExpectations(timeout: 15)
    shot("4-terminal-sent")
  }

  /// Starts an agent from the composer in a new worktree. The harness
  /// checks on the Mac that the worktree and the agent's pane exist.
  /// `CODANS_E2E_COMPOSER_PROMPT` is the first message.
  @MainActor
  func testComposerStartsAnAgentInANewWorktree() throws {
    guard let prompt = env["CODANS_E2E_COMPOSER_PROMPT"], !prompt.isEmpty else {
      throw XCTSkip("CODANS_E2E_COMPOSER_PROMPT is not set; run docs/user-tests/ios-companion/harness.sh")
    }
    let app = XCUIApplication()
    _ = try pairAndOpenWorkspace(app)
    shot("1-home")

    let pill = app.descendants(matching: .any)["composer-pill"].firstMatch
    XCTAssertTrue(pill.waitForExistence(timeout: 10), "no composer for an interactive device")
    pill.tap()
    let field = app.descendants(matching: .any)["composer-prompt"].firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5), "composer never opened")
    shot("2-composer-open")
    // The worktree row is a menu: existing worktrees, then "New Worktree".
    let target = app.descendants(matching: .any)["composer-target"].firstMatch
    XCTAssertTrue(target.waitForExistence(timeout: 5), "composer has no worktree row")
    target.tap()
    let newWorktree = app.buttons["composer-new-worktree"]
    XCTAssertTrue(newWorktree.waitForExistence(timeout: 5), "worktree menu has no New Worktree")
    newWorktree.tap()
    field.tap()
    field.typeText(prompt)
    shot("3-composer-typed")
    app.buttons["composer-send"].tap()

    // The launch opens the agent's terminal, which shows the prompt (the
    // fake agent echoes its arguments).
    let text = app.descendants(matching: .any)["terminal-text"].firstMatch
    XCTAssertTrue(text.waitForExistence(timeout: 30), "never navigated to the new agent's pane")
    expectation(for: NSPredicate(format: "value CONTAINS %@", prompt), evaluatedWith: text)
    waitForExpectations(timeout: 20)
    shot("4-agent-pane")
  }

  /// Opens the harness's pairing link, confirms it, and waits until the
  /// workspace lists the fixture project and the connection has settled.
  /// Returns the first worktree row.
  @MainActor
  private func pairAndOpenWorkspace(_ app: XCUIApplication) throws -> XCUIElement {
    guard let code = env["CODANS_E2E_PAIRING_CODE"], !code.isEmpty else {
      throw XCTSkip("CODANS_E2E_PAIRING_CODE is not set; run docs/user-tests/ios-companion/harness.sh")
    }
    let project = env["CODANS_E2E_PROJECT"] ?? "fixture"
    app.launch()
    app.open(try XCTUnwrap(URL(string: code)))

    // iOS first asks whether to open the link in the app (SpringBoard owns
    // that prompt; its button is localized).
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let open = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
    if open.waitForExistence(timeout: 5) { open.tap() }

    let pair = app.alerts.buttons["Pair"]
    XCTAssertTrue(pair.waitForExistence(timeout: 10), "pairing confirmation never appeared")
    shot("0-confirm")
    pair.tap()

    // The home screen lists each project with its worktrees.
    let projectHeader = app.staticTexts[project]
    XCTAssertTrue(projectHeader.waitForExistence(timeout: 20), "project \(project) never listed")
    let worktreeRow = app.descendants(matching: .any)["worktree-row"].firstMatch
    XCTAssertTrue(worktreeRow.waitForExistence(timeout: 5), "project has no worktree rows")
    // The connection strip above the list disappears once live and shifts
    // the rows up; a tap during that shift lands on empty space.
    let banner = app.descendants(matching: .any)["connection-banner"].firstMatch
    _ = banner.waitForNonExistence(timeout: 20)
    shot("1-worktrees")
    return worktreeRow
  }

  @MainActor
  private func shot(_ name: String) {
    let png = XCUIScreen.main.screenshot().pngRepresentation
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    if let dir = env["CODANS_E2E_SHOTS"], !dir.isEmpty {
      try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
  }
}
