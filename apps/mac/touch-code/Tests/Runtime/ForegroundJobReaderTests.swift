import Testing
import TouchCodeCore

@testable import TouchCode

struct ForegroundJobReaderTests {
  @Test
  func parseProcessLineReadsPsSnapshotFields() {
    let process = ForegroundJobReader.parseProcessLine(
      " 34915 34914 34914 /Users/me/.local/bin/codex --resume"
    )

    #expect(process?.pid == 34915)
    #expect(process?.parentPID == 34914)
    #expect(process?.processGroupID == 34914)
    #expect(process?.argv0 == "/Users/me/.local/bin/codex")
    #expect(process?.commandLine == "/Users/me/.local/bin/codex --resume")
  }

  @Test
  func parseProcessLineRejectsIncompleteRows() {
    #expect(ForegroundJobReader.parseProcessLine("34915 34914") == nil)
    #expect(ForegroundJobReader.parseProcessLine("34915 34914 34914") == nil)
  }
}
