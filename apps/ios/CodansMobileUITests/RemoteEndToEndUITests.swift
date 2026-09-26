import XCTest

/// End to end against a live Mac gateway: open a pairing link, confirm,
/// browse to a pane, read it, and send a line into it. Driven by
/// `docs/user-tests/ios-companion/harness.sh`, which starts an isolated Mac
/// instance and passes its values through `TEST_RUNNER_`-prefixed
/// environment variables; without them the test is skipped, so a plain
/// `make test` never needs a Mac.
///
/// - `CODANS_E2E_PAIR=1`: pair first, with a `codans-pair:` code the
///   harness writes to `pairing-code` in the hand-off directory once the
///   app is up. Other tests run on the pairing an earlier test left behind
///   and need `CODANS_E2E_PAIRED=1` instead.
/// - `CODANS_E2E_PROJECT`: name of the project whose first pane to open.
/// - `CODANS_E2E_INPUT`: line to send; omitted for a view-only device.
/// - `CODANS_E2E_MARKER`: text the Mac prints (live output) or the phone
///   types (live input).
/// - `CODANS_E2E_COMPOSER_PROMPT`: first message for the composer test.
/// - `CODANS_E2E_SYNC`: host directory for hand-offs with the harness (see
///   `handOff(_:)`).
/// - `CODANS_E2E_SHOTS`: host directory for step screenshots (optional).
final class RemoteEndToEndUITests: XCTestCase {
  private var env: [String: String] { ProcessInfo.processInfo.environment }

  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testPairBrowseReadAndSend() throws {
    let app = XCUIApplication()
    let text = try openTerminal(app)
    shot("3-terminal-open")

    let keyBar = app.descendants(matching: .any)["terminal-key-bar"].firstMatch
    guard let line = env["CODANS_E2E_INPUT"], !line.isEmpty else {
      // View-only device: the key bar must never appear.
      XCTAssertFalse(keyBar.waitForExistence(timeout: 3), "view-only device shows the key bar")
      shot("4-terminal-readonly")
      return
    }
    XCTAssertTrue(keyBar.waitForExistence(timeout: 10), "interactive device has no key bar")
    type(line + "\n", in: app)

    // The Mac's pane echoes the line back over the stream.
    expectation(for: NSPredicate(format: "value CONTAINS %@", line), evaluatedWith: text)
    waitForExpectations(timeout: 15)
    shot("4-terminal-sent")
  }

  /// Live output: once the phone shows the pane, the harness prints
  /// `CODANS_E2E_MARKER` in it on the Mac, and the phone must show it
  /// without reopening anything. Also used for a view-only device, which
  /// must stream the same way but never offer the key bar.
  @MainActor
  func testShowsLiveOutput() throws {
    let marker = try required("CODANS_E2E_MARKER")
    let app = XCUIApplication()
    let text = try openTerminal(app)
    handOff("attached")
    expectation(for: NSPredicate(format: "value CONTAINS %@", marker), evaluatedWith: text)
    waitForExpectations(timeout: 15)
    shot("live-output")
    if env["CODANS_E2E_READ_ONLY"] == "1" {
      let keyBar = app.descendants(matching: .any)["terminal-key-bar"].firstMatch
      XCTAssertFalse(keyBar.exists, "view-only device shows the key bar")
      screenOf(app).tap()
      XCTAssertFalse(keyBar.waitForExistence(timeout: 3), "a tap on a view-only terminal raised the key bar")
      XCTAssertFalse(app.keyboards.firstMatch.exists, "a tap on a view-only terminal raised the keyboard")
      shot("live-output-readonly")
    }
  }

  /// Live input: the phone types `echo <marker>` and Return through the
  /// terminal's own keyboard input; the harness finds the output line in
  /// the Mac's pane.
  @MainActor
  func testTypesIntoTheMacPane() throws {
    let marker = try required("CODANS_E2E_MARKER")
    let app = XCUIApplication()
    let text = try openTerminal(app)
    type("echo \(marker)\n", in: app)
    // The echo comes back as its own line, not just the typed command.
    expectation(for: NSPredicate(format: "value MATCHES %@", "(?s).*\\n\(marker)\\s*\\n.*"), evaluatedWith: text)
    waitForExpectations(timeout: 15)
    shot("live-input")
  }

  /// Ctrl latch: the harness starts `sleep 30` in the pane; the phone arms
  /// ctrl on the key bar and types `c`. The harness then checks the shell
  /// answers again long before the sleep would end.
  @MainActor
  func testCtrlLatchInterruptsAForegroundJob() throws {
    let app = XCUIApplication()
    _ = try openTerminal(app)
    raiseKeyboard(app)
    handOff("ready")  // the harness starts `sleep 30`
    let ctrl = app.descendants(matching: .any)["key-ctrl"].firstMatch
    XCTAssertTrue(ctrl.waitForExistence(timeout: 5), "key bar has no ctrl")
    ctrl.tap()
    XCTAssertEqual(ctrl.value as? String, "On", "ctrl did not latch")
    shot("modifier-armed")
    app.typeText("c")
    // A latch is one-shot: the key after it releases ctrl.
    expectation(for: NSPredicate(format: "value == %@", "Off"), evaluatedWith: ctrl)
    waitForExpectations(timeout: 5)
    handOff("interrupted")
    shot("modifier-sent")
  }

  /// The phone watches without owning the PTY size: after it types into
  /// the pane, the harness checks `stty size` did not move, then resizes
  /// the Mac window and checks the size follows the Mac.
  @MainActor
  func testLeavesTheSizeToTheMac() throws {
    let app = XCUIApplication()
    _ = try openTerminal(app)
    type("true\n", in: app)
    handOff("typed")
    handOff("resized", timeout: 90)
    shot("no-leader-steal")
  }

  /// Tab operations from the terminal's title menu. The harness checks the
  /// Mac's tree after each step.
  @MainActor
  func testManagesTabsAndPanes() throws {
    let app = XCUIApplication()
    _ = try openTerminal(app)

    pick("New Tab", in: app)
    handOff("new-tab")
    pick("Split Right", in: app)
    handOff("split")
    shot("tab-ops-split")
    pick("Close Pane…", in: app)
    let confirm = app.buttons["Close Pane"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5), "closing a pane asked for no confirmation")
    shot("tab-ops-confirm")
    confirm.tap()
    handOff("closed")
  }

  /// Revocation while connected: the harness revokes every device on the
  /// Mac, and the phone must end on the removed state with Pair again
  /// instead of retrying forever.
  @MainActor
  func testShowsRemovedAfterRevocation() throws {
    let app = XCUIApplication()
    _ = try openWorkspace(app)
    handOff("live")  // the harness revokes the device
    let pairAgain = app.descendants(matching: .any)["connection-pair-again"].firstMatch
    XCTAssertTrue(pairAgain.waitForExistence(timeout: 90), "a revoked device never asked to pair again")
    shot("rejected")
  }

  /// Acceptance screenshots against a real Mac, driven by
  /// `docs/user-tests/ios-companion/tour.sh`: home, an agent's terminal, the
  /// key bar, the title menu, reconnecting while the Mac is gone, and the
  /// removed state after the Mac revokes the device. Screenshot names start
  /// with `CODANS_E2E_TOUR_PREFIX`; `CODANS_E2E_WORKTREE` picks the worktree
  /// row whose label contains it.
  @MainActor
  func testAcceptanceTour() throws {
    let prefix = try required("CODANS_E2E_TOUR_PREFIX")
    let app = XCUIApplication()
    _ = try openWorkspace(app)
    shot("\(prefix)-1-home")

    let label = env["CODANS_E2E_WORKTREE"] ?? ""
    let rows = app.descendants(matching: .any).matching(identifier: "worktree-row")
    let row = label.isEmpty ? rows.firstMatch : rows.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5), "no worktree row for \(label)")
    row.tap()
    let text = app.descendants(matching: .any)["terminal-text"].firstMatch
    XCTAssertTrue(text.waitForExistence(timeout: 15), "terminal never rendered")
    expectation(for: NSPredicate(format: "value CONTAINS %@", "Claude Code"), evaluatedWith: text)
    waitForExpectations(timeout: 15)
    sleep(1)
    shot("\(prefix)-2-terminal")

    raiseKeyboard(app)
    app.typeText("also cover the timeout path")
    sleep(1)
    shot("\(prefix)-3-key-bar")

    let menu = app.descendants(matching: .any)["tab-menu"].firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 5), "terminal has no title menu")
    menu.tap()
    XCTAssertTrue(app.buttons["New Tab"].waitForExistence(timeout: 5), "title menu never opened")
    sleep(1)
    shot("\(prefix)-4-tab-menu")
    // A tap outside the menu closes it without picking anything.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
    _ = app.buttons["New Tab"].waitForNonExistence(timeout: 5)

    handOff("quit", timeout: 90)  // the harness quits the Mac instance
    let reconnecting = app.descendants(matching: .any)["terminal-reconnecting"].firstMatch
    XCTAssertTrue(reconnecting.waitForExistence(timeout: 30), "the terminal never showed it was reconnecting")
    sleep(3)
    shot("\(prefix)-5-reconnecting")

    handOff("relaunched", timeout: 120)  // the harness starts the Mac again
    XCTAssertTrue(reconnecting.waitForNonExistence(timeout: 60), "the terminal never reconnected")
    sleep(2)
    shot("\(prefix)-6-reconnected")

    handOff("live", timeout: 120)  // the harness revokes the device
    let pairAgain = app.descendants(matching: .any)["connection-pair-again"].firstMatch
    XCTAssertTrue(pairAgain.waitForExistence(timeout: 90), "a revoked device never asked to pair again")
    sleep(1)
    shot("\(prefix)-7-rejected")
  }

  /// Starts an agent from the composer in a new worktree. The harness
  /// checks on the Mac that the worktree and the agent's pane exist.
  /// `CODANS_E2E_COMPOSER_PROMPT` is the first message.
  @MainActor
  func testComposerStartsAnAgentInANewWorktree() throws {
    let prompt = try required("CODANS_E2E_COMPOSER_PROMPT")
    let app = XCUIApplication()
    _ = try openWorkspace(app)
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

  // MARK: - Steps

  /// Opens the workspace, taps the first worktree and waits until its
  /// terminal shows the pane's screen. Returns the terminal's text element,
  /// whose value is the visible screen.
  @MainActor
  private func openTerminal(_ app: XCUIApplication) throws -> XCUIElement {
    let worktreeRow = try openWorkspace(app)
    worktreeRow.tap()

    // A worktree opens straight onto its terminal: the pane last viewed
    // there, else the Mac's focused pane.
    let screen = screenOf(app)
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
    return text
  }

  /// Pairs from the harness's link when it passed one, else launches on the
  /// pairing an earlier test left. Waits until the workspace lists the
  /// fixture project and the connection has settled; returns the first
  /// worktree row.
  @MainActor
  private func openWorkspace(_ app: XCUIApplication) throws -> XCUIElement {
    let pairs = env["CODANS_E2E_PAIR"] == "1"
    guard pairs || env["CODANS_E2E_PAIRED"] == "1" else {
      throw XCTSkip("CODANS_E2E_PAIR is not set; run docs/user-tests/ios-companion/harness.sh")
    }
    let project = env["CODANS_E2E_PROJECT"] ?? "fixture"
    // The simulator shares the Mac's keyboard, which hides the key bar
    // these tests drive.
    app.launchEnvironment["CODANS_FORCE_KEY_BAR"] = "1"
    app.launch()
    if pairs {
      // The code comes from the harness only now: a code expires ten
      // minutes after the Mac issues it, and the test runner can take
      // that long to start.
      handOff("pair")
      let code = try String(contentsOfFile: try syncPath("pairing-code"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      app.open(try XCTUnwrap(URL(string: code)))

      // iOS first asks whether to open the link in the app (SpringBoard
      // owns that prompt; its button is localized).
      let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      let open = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
      if open.waitForExistence(timeout: 5) { open.tap() }

      let pair = app.alerts.buttons["Pair"]
      XCTAssertTrue(pair.waitForExistence(timeout: 10), "pairing confirmation never appeared")
      shot("0-confirm")
      pair.tap()
    }

    // The home screen lists each project with its worktrees.
    let projectHeader = app.staticTexts[project]
    XCTAssertTrue(projectHeader.waitForExistence(timeout: 60), "project \(project) never listed")
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
  private func screenOf(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["terminal-screen"].firstMatch
  }

  /// A tap on the screen gives the terminal the keyboard.
  @MainActor
  private func raiseKeyboard(_ app: XCUIApplication) {
    let keyBar = app.descendants(matching: .any)["terminal-key-bar"].firstMatch
    if !keyBar.exists { screenOf(app).tap() }
    XCTAssertTrue(keyBar.waitForExistence(timeout: 10), "interactive device has no key bar")
  }

  /// Types through the terminal's keyboard input, the path a person uses.
  @MainActor
  private func type(_ text: String, in app: XCUIApplication) {
    raiseKeyboard(app)
    app.typeText(text)
  }

  /// Picks an item from the terminal's title menu.
  @MainActor
  private func pick(_ item: String, in app: XCUIApplication) {
    let menu = app.descendants(matching: .any)["tab-menu"].firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 10), "terminal has no title menu")
    menu.tap()
    let button = app.buttons[item]
    XCTAssertTrue(button.waitForExistence(timeout: 5), "title menu has no \(item)")
    button.tap()
  }

  // MARK: - Harness

  @MainActor
  private func required(_ name: String) throws -> String {
    guard let value = env[name], !value.isEmpty else {
      throw XCTSkip("\(name) is not set; run docs/user-tests/ios-companion/harness.sh")
    }
    return value
  }

  /// Hands control to the harness and waits for it to hand back: writes
  /// `<step>.phone` into `CODANS_E2E_SYNC` and waits for `<step>.mac`. The
  /// harness does its Mac-side part in between (print, resize, check the
  /// tree). A simulator test reads and writes host paths directly.
  @MainActor
  private func handOff(_ step: String, timeout: TimeInterval = 60) {
    guard let mine = try? syncPath("\(step).phone"), let reply = try? syncPath("\(step).mac") else {
      XCTFail("CODANS_E2E_SYNC is not set")
      return
    }
    FileManager.default.createFile(atPath: mine, contents: nil)
    let deadline = Date().addingTimeInterval(timeout)
    while !FileManager.default.fileExists(atPath: reply) {
      guard Date() < deadline else {
        XCTFail("the harness never finished step \(step)")
        return
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
  }

  /// A file in the hand-off directory.
  @MainActor
  private func syncPath(_ name: String) throws -> String {
    guard let dir = env["CODANS_E2E_SYNC"], !dir.isEmpty else {
      throw XCTSkip("CODANS_E2E_SYNC is not set; run docs/user-tests/ios-companion/harness.sh")
    }
    return URL(fileURLWithPath: dir).appendingPathComponent(name).path
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
