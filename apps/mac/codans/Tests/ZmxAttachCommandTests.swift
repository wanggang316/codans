import Testing
import CodansCore

@testable import Codans

/// `ZmxAttachCommand` composes how a surface launches under zmx. These guard
/// a stable session name (so re-attach reuses the same daemon across
/// launches), the wrapper argv libghostty prepends to the resolved shell, and
/// correct single-quote escaping of the `/bin/sh -c` command string.
struct ZmxAttachCommandTests {
  @Test
  func sessionIsThePaneUUID() {
    let paneID = PaneID()
    #expect(ZmxAttachCommand.session(for: paneID) == paneID.raw.uuidString)
  }

  @Test
  func buildWithoutUserCommandIsBareAttach() {
    let cmd = ZmxAttachCommand.build(zmxPath: "/Apps/zmx", session: "abc", userCommand: nil)
    #expect(cmd == "'/Apps/zmx' attach 'abc'")
  }

  @Test
  func blankUserCommandIsBareAttach() {
    let cmd = ZmxAttachCommand.build(zmxPath: "/Apps/zmx", session: "abc", userCommand: "   ")
    #expect(cmd == "'/Apps/zmx' attach 'abc'")
  }

  @Test
  func userCommandAppendsShellWrapper() {
    let cmd = ZmxAttachCommand.build(zmxPath: "/Apps/zmx", session: "abc", userCommand: "echo hi")
    #expect(cmd == "'/Apps/zmx' attach 'abc' /bin/sh -c 'echo hi'")
  }

  @Test
  func shellQuoteEscapesSingleQuotes() {
    #expect(ZmxAttachCommand.shellQuote("it's") == #"'it'\''s'"#)
  }

  @Test
  func pathWithSpacesIsQuoted() {
    let cmd = ZmxAttachCommand.build(zmxPath: "/Users/a b/zmx", session: "s", userCommand: nil)
    #expect(cmd == "'/Users/a b/zmx' attach 's'")
  }

  @Test
  func wrapperArgvIsSplitAttachWithoutQuoting() {
    let argv = ZmxAttachCommand.wrapperArgv(zmxPath: "/Users/a b/zmx", session: "abc")
    #expect(argv == ["/Users/a b/zmx", "attach", "abc"])
  }

  @Test
  func wrapperArgvCarriesRestoreFromAfterSession() {
    let argv = ZmxAttachCommand.wrapperArgv(
      zmxPath: "/Apps/zmx", session: "abc", restoreFrom: "/a b/it's.snap")
    #expect(argv == ["/Apps/zmx", "attach", "abc", "--restore-from", "/a b/it's.snap"])
  }

  @Test
  func wrapperArgvIgnoresBlankRestoreFrom() {
    let bare = ["/Apps/zmx", "attach", "abc"]
    #expect(ZmxAttachCommand.wrapperArgv(zmxPath: "/Apps/zmx", session: "abc", restoreFrom: "  ") == bare)
    #expect(ZmxAttachCommand.wrapperArgv(zmxPath: "/Apps/zmx", session: "abc", restoreFrom: nil) == bare)
  }
}
