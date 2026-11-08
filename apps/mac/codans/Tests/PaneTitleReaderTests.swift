import CodansCore
import Foundation
import Testing

@testable import Codans

/// ADR 0009: the tab chip mirrors the header of its selected pane, and an
/// empty OSC 0/2 title keeps the last one.
@MainActor
struct PaneTitleReaderTests {
  @Test(arguments: [
    (live: "~/dev/codans" as String?, stored: "~/dev/codans" as String?),
    (live: "✳ Claude Code", stored: "~/dev/codans"),
    (live: nil, stored: "~/dev/codans"),
    (live: nil, stored: nil)
  ])
  func chipWithoutNameOrCacheShowsTheHeaderText(live: String?, stored: String?) {
    let header = PaneTitleReader.headerTitle(live: live, stored: stored)
    let chip = PaneTitleReader.chipTitle(
      tabName: nil, live: live, cached: nil, stored: stored ?? PaneTitle.placeholder,
      emptyTabTitle: "repo")
    #expect(chip == header)
  }

  @Test
  func liveTitleWinsOverTheCache() {
    let chip = PaneTitleReader.chipTitle(
      tabName: nil, live: "~/dev/codans", cached: "Claude Code", stored: "~/dev/codans",
      emptyTabTitle: "repo")
    #expect(chip == "~/dev/codans")
  }

  @Test
  func cacheStandsInOnlyWithoutASurface() {
    let chip = PaneTitleReader.chipTitle(
      tabName: nil, live: nil, cached: "✳ Claude Code", stored: "~/dev/codans",
      emptyTabTitle: "repo")
    #expect(chip == "✳ Claude Code")
  }

  @Test
  func tabNameWins() {
    let chip = PaneTitleReader.chipTitle(
      tabName: "Server", live: "~/dev/codans", cached: nil, stored: nil, emptyTabTitle: "repo")
    #expect(chip == "Server")
    let unnamed = PaneTitleReader.chipTitle(
      tabName: "", live: nil, cached: nil, stored: nil, emptyTabTitle: "repo")
    #expect(unnamed == "repo")
  }

  @Test
  func emptyTitleKeepsTheLastTitle() {
    let info = SurfaceInfo()
    info.applyTitle("make test")
    info.applyTitle("")
    #expect(info.title == "")
    #expect(info.lastTitle == "make test")
    info.applyTitle(nil)
    #expect(info.lastTitle == "make test")
    info.applyTitle("vim")
    #expect(info.lastTitle == "vim")
  }

  @Test
  func storedTitleIsThePersistedDirectory() {
    let pane = Pane(workingDirectory: NSHomeDirectory() + "/dev")
    #expect(PaneTitleReader.storedTitle(pane: pane) == "~/dev")
    #expect(PaneTitleReader.storedTitle(pane: nil) == nil)
  }
}
