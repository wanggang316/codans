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
/// - `CODANS_E2E_SHOTS`: host directory for step screenshots (optional).
final class RemoteEndToEndUITests: XCTestCase {
  private var env: [String: String] { ProcessInfo.processInfo.environment }

  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testPairBrowseReadAndSend() throws {
    guard let code = env["CODANS_E2E_PAIRING_CODE"], !code.isEmpty else {
      throw XCTSkip("CODANS_E2E_PAIRING_CODE is not set; run docs/user-tests/ios-companion/harness.sh")
    }
    let project = env["CODANS_E2E_PROJECT"] ?? "fixture"

    let app = XCUIApplication()
    app.launch()
    app.open(try XCTUnwrap(URL(string: code)))

    // iOS first asks whether to open the link in the app (SpringBoard owns
    // that prompt; its button is localized).
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let open = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
    if open.waitForExistence(timeout: 5) { open.tap() }

    let pair = app.alerts.buttons["Pair"]
    XCTAssertTrue(pair.waitForExistence(timeout: 10), "pairing confirmation never appeared")
    shot("1-confirm")
    pair.tap()

    app.tabBars.buttons["Browse"].tap()
    let projectRow = app.staticTexts[project]
    XCTAssertTrue(projectRow.waitForExistence(timeout: 20), "project \(project) never listed")
    shot("2-projects")
    projectRow.tap()

    // By identifier: in compact width the collapsed project list stays in
    // the accessibility tree, so "first cell" would hit the project row.
    let paneRow = app.descendants(matching: .any)["pane-row"].firstMatch
    XCTAssertTrue(paneRow.waitForExistence(timeout: 10), "project has no pane rows")
    shot("3-panes")
    paneRow.tap()

    // The pane's text arrives from `pane.read`; an empty dump means the
    // phone shows a blank page.
    let output = app.staticTexts["pane-output"]
    XCTAssertTrue(output.waitForExistence(timeout: 10), "pane text never loaded")
    shot("4-pane-open")
    XCTAssertFalse(output.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "pane text is empty")

    let input = app.textFields["Send to pane"]
    guard let line = env["CODANS_E2E_INPUT"], !line.isEmpty else {
      // View-only device: the input bar must never appear.
      XCTAssertFalse(input.waitForExistence(timeout: 3), "view-only device shows the input bar")
      shot("5-pane-readonly")
      return
    }
    XCTAssertTrue(input.waitForExistence(timeout: 10), "interactive device has no input bar")
    input.tap()
    input.typeText(line)
    app.buttons["pane-send"].tap()

    // The pane refreshes while visible; the echoed line comes back.
    let echoed = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", line)).firstMatch
    XCTAssertTrue(echoed.waitForExistence(timeout: 15), "sent line never showed up in the pane")
    shot("5-pane-sent")
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
