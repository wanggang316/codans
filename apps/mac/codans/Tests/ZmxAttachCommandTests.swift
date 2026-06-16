import Testing
import CodansCore

@testable import Codans

/// `ZmxAttachCommand` composes the exec-backend surface command. These guard
/// the wire shape libghostty hands to `/bin/sh -c`: a stable session name (so
/// re-attach reuses the same daemon across launches) and correct single-quote
/// escaping (so paths / scripts with spaces or quotes survive the wrapping).
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
  func nilRestoreFromIsByteIdenticalToBareAttach() {
    let cmd = ZmxAttachCommand.build(
      zmxPath: "/Apps/zmx", session: "abc", userCommand: nil, restoreFrom: nil)
    #expect(cmd == "'/Apps/zmx' attach 'abc'")
  }

  @Test
  func blankRestoreFromIsIgnored() {
    let cmd = ZmxAttachCommand.build(
      zmxPath: "/Apps/zmx", session: "abc", userCommand: nil, restoreFrom: "   ")
    #expect(cmd == "'/Apps/zmx' attach 'abc'")
  }

  @Test
  func restoreFromEmitsFlagAfterSession() {
    let cmd = ZmxAttachCommand.build(
      zmxPath: "/Apps/zmx", session: "abc", userCommand: nil, restoreFrom: "/p")
    #expect(cmd == "'/Apps/zmx' attach 'abc' --restore-from '/p'")
  }

  @Test
  func restoreFromPrecedesUserCommandWrapper() {
    let cmd = ZmxAttachCommand.build(
      zmxPath: "/Apps/zmx", session: "abc", userCommand: "cmd", restoreFrom: "/p")
    #expect(cmd == "'/Apps/zmx' attach 'abc' --restore-from '/p' /bin/sh -c 'cmd'")
  }

  @Test
  func restoreFromPathWithSpaceAndQuoteSurvivesQuoting() {
    let cmd = ZmxAttachCommand.build(
      zmxPath: "/Apps/zmx", session: "abc", userCommand: "cmd", restoreFrom: "/a b/it's.snap")
    #expect(cmd == #"'/Apps/zmx' attach 'abc' --restore-from '/a b/it'\''s.snap' /bin/sh -c 'cmd'"#)
  }
}
