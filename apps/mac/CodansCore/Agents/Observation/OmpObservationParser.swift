import Foundation

nonisolated struct OmpObservationParser: AgentTerminalParser {
  func parse(_ text: String) -> TerminalParseResult {
    let screen = AgentObservationText.interactionLines(text, promptPrefixes: ["omp>", "❯"]).joined(separator: "\n")
    return AgentObservationText.result(activity: Self.detectOmp(screen), text: screen, promptPrefixes: ["omp>", "❯"])
  }

  private static func detectOmp(_ content: String) -> AgentObservedActivity {
    let lower = content.lowercased()
    // Approval selector: omp's tool-approval prompt titles the dialog
    // `Allow tool: <name>` and renders Approve/Deny as select-list rows
    // (cursor-prefixed), so require them as standalone option lines. The
    // title is matched line-initially: a transcript that merely quotes
    // the cue (docs, this classifier's own source) must not read as the
    // dialog — observed live as a working pane badging blocked.
    if hasOmpApprovalTitle(content) || hasOmpSelectorOptions(content)
      || hasOmpAskFooter(content)
    {
      return .blocked
    }
    // Working loader: omp renders the live working line as
    // `<message>…<bracketed esc>` (verified live on v18.0.7:
    // `⠋ Working… ⟦esc⟧` under the titanium theme; ASCII `[esc]` on
    // default themes). The hint renders only while a turn is running.
    if lower.contains("working…") || hasOmpInterruptHint(content) {
      return .working
    }
    // Long-turn chrome (verified live 2026-09, post-v18 builds): a turn
    // that streams no transcript output for minutes leaves only the
    // status bar's spinner + elapsed-turn timer on screen, optionally a
    // glyph-first activity line for the running tool / phase. Both are
    // fixed-region chrome — never transcript shape — so they read as
    // working without pinning a finished agent after the turn ends.
    if hasOmpTurnTimer(content) || hasOmpActivityLine(content) {
      return .working
    }
    return .unknown
  }

  /// The bracket pair is theme-configurable (`[esc]`, `⟦esc⟧`, …), so
  /// match the shape: an `esc` token trailing the message's ellipsis on
  /// one line. Transcript lines never carry that shape.
  private static func hasOmpInterruptHint(_ content: String) -> Bool {
    content.split(separator: "\n").contains { line in
      let lowered = line.lowercased()
      guard let ellipsis = lowered.range(of: "…") else { return false }
      return lowered[ellipsis.upperBound...].contains("esc")
    }
  }

  /// The status bar a running turn renders: a braille spinner frame
  /// followed by the turn's elapsed time and the `>`-separated context
  /// chain — `⠸ 9m > ◉ GLM-5.3 > …` (spacing varies by theme and width).
  /// The idle composer's header opens with the box border / `π`, never a
  /// spinner-plus-timer pair, and transcript lines do not take that shape.
  private static func hasOmpTurnTimer(_ content: String) -> Bool {
    content.split(separator: "\n").contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let first = trimmed.unicodeScalars.first,
        (0x2800...0x28FF).contains(Int(first.value))
      else { return false }
      // omp themes separate the spinner from the timer — and timer groups
      // from the `>` chain — with plain or non-breaking spaces, and
      // `CharacterSet.whitespaces` leaves U+00A0 in place, so skip
      // Unicode whitespace explicitly (`Character.isWhitespace`).
      var rest = String(trimmed.unicodeScalars.dropFirst()).drop { $0.isWhitespace }
      // One or more `<digits><s|m|h>` elapsed groups: `45s`, `9m`, `1h 5m`.
      var matchedUnit = false
      while let leading = rest.first, leading.isNumber {
        let digits = rest.prefix(while: \.isNumber)
        rest = String(rest.dropFirst(digits.count)).drop { $0.isWhitespace }
        guard let unit = rest.first, "smh".contains(unit) else { return false }
        rest = String(rest.dropFirst()).drop { $0.isWhitespace }
        matchedUnit = true
      }
      return matchedUnit && rest.hasPrefix(">")
    }
  }

  /// Glyph-first activity line under the collapsed input box while a turn
  /// runs: the hourglass tool line (`⏳ Grep: …`), or the sparkle phase
  /// line (`❖ Exploring codans commands`). The glyph leads the line and a
  /// space follows it; prose quoting the glyphs mid-line does not match,
  /// and the idle composer renders neither shape.
  private static func hasOmpActivityLine(_ content: String) -> Bool {
    let activityGlyphs: Set<Character> = ["⏳", "❖"]
    return content.split(separator: "\n").contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let first = trimmed.first, activityGlyphs.contains(first) else {
        return false
      }
      return trimmed.dropFirst().first == " "
    }
  }

  /// omp's approval dialog titles itself at the start of a line
  /// (`Allow tool: bash`); transcript prose quoting the title mid-line is
  /// not the dialog.
  private static func hasOmpApprovalTitle(_ content: String) -> Bool {
    content.split(separator: "\n").contains { line in
      line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("allow tool:")
    }
  }

  /// The `ask` tool's question selector renders no approval title — only
  /// unnumbered option rows plus a key-hint footer built from fixed
  /// templates (verified in the v18.2.8 bundle): single-select
  /// `Enter select · n note · ↑/↓ move · … · Esc cancel`, multi-select
  /// `Space toggle · Enter next|submit · ↑/↓ …`, and the review page
  /// `Enter submit · ↑/↓ scroll · … cancel`. Matched line-initially and
  /// only with the trailing cancel hint, so prose quoting a fragment is
  /// not the dialog.
  private static func hasOmpAskFooter(_ content: String) -> Bool {
    let footerPrefixes = [
      "enter select · n note", "space toggle · enter ", "enter submit · ↑/↓ scroll",
    ]
    return content.split(separator: "\n").contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
      return footerPrefixes.contains(where: trimmed.hasPrefix) && trimmed.contains(" cancel")
    }
  }

  private static func hasOmpSelectorOptions(_ content: String) -> Bool {
    var hasApprove = false
    var hasDeny = false
    for line in content.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == "Approve" || trimmed == "❯ Approve" { hasApprove = true }
      if trimmed == "Deny" || trimmed == "❯ Deny" { hasDeny = true }
    }
    return hasApprove && hasDeny
  }

}
