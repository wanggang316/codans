import CodansCore
import Foundation
import Testing

@testable import Codans

struct ZmxOutputScannerTests {
  private func scan(_ chunks: String...) -> [DetachedPaneSignal] {
    var scanner = ZmxOutputScanner()
    return chunks.flatMap { scanner.scan(Data($0.utf8)) }
  }

  @Test
  func readsTitlesWithBothTerminators() {
    #expect(
      scan("plain\u{1B}]0;first\u{07}text\u{1B}]2;second\u{1B}\\")
        == [.title("first"), .title("second")])
  }

  @Test
  func keepsStateAcrossFrames() {
    #expect(
      scan("\u{1B}", "]7501;state=work", "ing:app=claude-code\u{1B}", "\\")
        == [.programStatus(ProgramStatusReport(state: .working, app: "claude-code"))])
  }

  @Test
  func readsNotificationsAndSkipsConEmuExtensions() {
    #expect(
      scan("\u{1B}]9;Build done\u{07}\u{1B}]9;4;1;40\u{07}\u{1B}]9;5\u{07}")
        == [.desktopNotification(title: "", body: "Build done")])
  }

  @Test
  func ignoresOtherSequencesAndAbortedStrings() {
    let signals = scan(
      "\u{1B}[31mred\u{1B}]52;c;aGVsbG8=\u{07}\u{1B}]0;cut\u{18}\u{1B}]0;interrupted\u{1B}[0m")
    #expect(signals.isEmpty)
  }

  @Test
  func restartsOnNewOSCInsideBody() {
    #expect(scan("\u{1B}]0;lost\u{1B}]0;kept\u{07}") == [.title("kept")])
  }

  @Test
  func dropsOverlongBodies() {
    let long = String(repeating: "a", count: ZmxOutputScanner.maxBodyBytes + 1)
    #expect(scan("\u{1B}]0;\(long)\u{07}\u{1B}]0;next\u{07}") == [.title("next")])
  }

  @Test
  func ignoresProgramStatusQuery() {
    #expect(scan("\u{1B}]7501;?\u{1B}\\").isEmpty)
  }
}

struct ProgramStatusParserTests {
  private func parse(_ body: String) -> ProgramStatusReport? {
    ProgramStatusParser.parse(body: Array(body.utf8))
  }

  @Test
  func parsesAllKeys() {
    // "Plan" and "Apply 3 to add, 1 to change, 0 to destroy?"
    let report = parse(
      "state=blocked:kind=permission:progress=42:id=tf/plan:app=terraform"
        + ":title=UGxhbg==:msg=QXBwbHkgMyB0byBhZGQsIDEgdG8gY2hhbmdlLCAwIHRvIGRlc3Ryb3k/")
    #expect(
      report
        == ProgramStatusReport(
          state: .blocked, kind: .permission, progress: 42, id: "tf/plan", app: "terraform",
          title: "Plan", message: "Apply 3 to add, 1 to change, 0 to destroy?"))
  }

  @Test
  func skipsUnknownAndMalformedPairs() {
    #expect(parse("state=idle:future=yes:oops") == ProgramStatusReport(state: .idle))
    #expect(parse(" state = done ") == ProgramStatusReport(state: .done))
  }

  @Test
  func lastValueWins() {
    #expect(parse("state=idle:state=working") == ProgramStatusReport(state: .working))
  }

  @Test
  func readsOptionsOnlyForTheirStates() {
    #expect(parse("state=idle:kind=auth:progress=10") == ProgramStatusReport(state: .idle))
    #expect(parse("state=working:progress=101")?.progress == nil)
    #expect(parse("state=working:progress=7")?.progress == 7)
    #expect(parse("state=blocked:kind=other")?.kind == nil)
  }

  @Test
  func acceptsUnpaddedBase64() {
    #expect(parse("state=done:title=UGxhbg")?.title == "Plan")
  }

  @Test(arguments: [
    "",
    "?",
    "app=x",
    "state=sleeping",
    "state=idle:id=a//b",
    "state=clear:id=a/",
    "state=idle:id=" + Array(repeating: "a", count: 9).joined(separator: "/"),
    "state=idle:averyveryverylongkey=1",
    "state=idle:app=" + String(repeating: "a", count: 33),
    "state=idle:msg=A",
    // "\u{07}" base64 encoded: control characters are rejected.
    "state=idle:msg=Bw==",
  ])
  func discardsInvalidReports(body: String) {
    #expect(parse(body) == nil)
  }

  @Test
  func skipsValuesOutsideTheAlphabet() {
    // Like libghostty, such a pair is skipped before any limit is checked.
    #expect(parse("state=idle:app=a b") == ProgramStatusReport(state: .idle))
    #expect(parse("state=idle:msg=!!!") == ProgramStatusReport(state: .idle))
  }
}
