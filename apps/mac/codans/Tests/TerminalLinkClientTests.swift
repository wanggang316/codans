import Foundation
import Testing

@testable import Codans

struct TerminalLinkClientTests {
  @Test(arguments: ["a.swift", "b.ts", "c.go", "notes.md", "config.json", "Makefile", "x.unknownext", "run.sh"])
  func sourceLikeFilesOpenInEditor(_ name: String) {
    #expect(!TerminalLinkClient.opensInDefaultApp(URL(fileURLWithPath: "/tmp/\(name)")))
  }

  @Test(arguments: ["shot.png", "diagram.svg", "report.pdf", "index.html"])
  func renderedDocumentsOpenInDefaultApp(_ name: String) {
    #expect(TerminalLinkClient.opensInDefaultApp(URL(fileURLWithPath: "/tmp/\(name)")))
  }
}
