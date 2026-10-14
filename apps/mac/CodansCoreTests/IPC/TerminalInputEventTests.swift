import Foundation
import Testing

@testable import CodansCore
@testable import CodansIPC

struct TerminalInputEventTests {
  private func decode(_ json: String) throws -> IPC.TerminalInputEvent {
    try JSONDecoder().decode(IPC.TerminalInputEvent.self, from: Data(json.utf8))
  }

  @Test
  func everyKnownKindRoundTrips() throws {
    let events: [IPC.TerminalInputEvent] = [
      .key(code: "KeyC", text: nil, mods: IPC.TerminalKeyModifiers(ctrl: true)),
      .key(code: "KeyA", text: "A", mods: IPC.TerminalKeyModifiers(shift: true)),
      .key(code: "ArrowUp", text: nil, mods: .none),
      .text("你好"),
      .paste("line 1\nline 2"),
      .delay(millis: 30),
    ]
    for event in events {
      let data = try JSONEncoder().encode(event)
      #expect(try JSONDecoder().decode(IPC.TerminalInputEvent.self, from: data) == event)
    }
  }

  @Test
  func keyIsFlatWithOptionalModifiers() throws {
    #expect(
      try decode(#"{"kind": "key", "code": "Enter"}"#) == .key(code: "Enter", text: nil, mods: .none))
    #expect(
      try decode(#"{"kind": "key", "code": "KeyD", "mods": {"ctrl": true}}"#)
        == .key(code: "KeyD", text: nil, mods: IPC.TerminalKeyModifiers(ctrl: true)))
    let json = try #require(
      JSONSerialization.jsonObject(
        with: JSONEncoder().encode(IPC.TerminalInputEvent.key(code: "Tab", text: nil, mods: .none)))
        as? [String: Any])
    #expect(json["kind"] as? String == "key")
    #expect(json["mods"] == nil)
    #expect(try decode(#"{"kind": "delay", "ms": 120}"#) == .delay(millis: 120))
  }

  @Test
  func unknownKindDecodesInsteadOfFailing() throws {
    #expect(try decode(#"{"kind": "mouse", "x": 3}"#) == .unknown(kind: "mouse"))
    let batch = try JSONDecoder().decode(
      IPC.TerminalSendEventsRequest.self,
      from: Data(
        #"{"paneID": {"raw": "\#(UUID().uuidString)"}, "events": [{"kind": "text", "text": "a"}, {"kind": "gesture"}]}"#.utf8))
    #expect(batch.events == [.text("a"), .unknown(kind: "gesture")])
  }

  @Test
  func knownKindWithMissingFieldFails() {
    #expect(throws: DecodingError.self) { try decode(#"{"kind": "key"}"#) }
    #expect(throws: DecodingError.self) { try decode(#"{"kind": "delay"}"#) }
  }

  @Test
  func resultRoundTrips() throws {
    let result = IPC.TerminalSendEventsResult(
      delivered: 2, rejected: [IPC.TerminalInputRejection(index: 1, reason: IPC.TerminalInputRejection.Reason.binding)])
    let data = try JSONEncoder().encode(result)
    #expect(try JSONDecoder().decode(IPC.TerminalSendEventsResult.self, from: data) == result)
  }
}
