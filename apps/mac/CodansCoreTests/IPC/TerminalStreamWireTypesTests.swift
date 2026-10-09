import CodansCore
import Foundation
import Testing

@testable import CodansIPC

struct TerminalStreamWireTypesTests {
  private func roundTrip(_ frame: IPC.TerminalStreamFrame) throws -> IPC.TerminalStreamFrame {
    try JSONDecoder().decode(IPC.TerminalStreamFrame.self, from: JSONEncoder().encode(frame))
  }

  private func json(_ frame: IPC.TerminalStreamFrame) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(frame))
    return try #require(object as? [String: Any])
  }

  @Test(arguments: [
    IPC.TerminalStreamPayload.reset(cols: 120, rows: 40, fidelity: .exact),
    .reset(cols: 80, rows: 24, fidelity: .approximate),
    .output(Data([0x1B, 0x5B, 0x48, 0x00, 0xFF])),
    .resized(cols: 100, rows: 30),
    .heartbeat,
    .exited(reason: "sessionEnded", exitCode: nil),
    .exited(reason: "sessionEnded", exitCode: 2),
  ])
  func everyKindRoundTrips(payload: IPC.TerminalStreamPayload) throws {
    let frame = IPC.TerminalStreamFrame(seq: 7, epoch: 2, payload: payload)
    #expect(try roundTrip(frame) == frame)
  }

  @Test
  func frameIsFlatWithBase64Output() throws {
    let frame = IPC.TerminalStreamFrame(seq: 3, epoch: 1, payload: .output(Data("hi".utf8)))
    let object = try json(frame)
    #expect(object["v"] as? Int == 1)
    #expect(object["seq"] as? Int == 3)
    #expect(object["epoch"] as? Int == 1)
    #expect(object["kind"] as? String == "output")
    #expect(object["data"] as? String == "aGk=")
  }

  @Test
  func resetCarriesSizeAndFidelity() throws {
    let object = try json(
      IPC.TerminalStreamFrame(seq: 1, epoch: 1, payload: .reset(cols: 90, rows: 30, fidelity: .approximate)))
    #expect(object["kind"] as? String == "reset")
    #expect(object["cols"] as? Int == 90)
    #expect(object["rows"] as? Int == 30)
    #expect(object["fidelity"] as? String == "approximate")
  }

  @Test
  func unknownKindDecodesAsUnknown() throws {
    let data = Data(#"{"v":1,"seq":9,"epoch":1,"kind":"bell","volume":3}"#.utf8)
    let frame = try JSONDecoder().decode(IPC.TerminalStreamFrame.self, from: data)
    #expect(frame.payload == .unknown(kind: "bell"))
    #expect(frame.seq == 9)
  }

  @Test
  func unknownFidelityIsApproximate() throws {
    let data = Data(#"{"v":1,"seq":1,"epoch":1,"kind":"reset","cols":80,"rows":24,"fidelity":"lossy"}"#.utf8)
    let frame = try JSONDecoder().decode(IPC.TerminalStreamFrame.self, from: data)
    #expect(frame.payload == .reset(cols: 80, rows: 24, fidelity: .approximate))
  }

  @Test
  func outputThatIsNotBase64IsRejected() {
    let data = Data(#"{"v":1,"seq":1,"epoch":1,"kind":"output","data":"***"}"#.utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(IPC.TerminalStreamFrame.self, from: data)
    }
  }

  @Test
  func attachRequestOptionalFieldsAreOmittable() throws {
    let paneID = PaneID()
    let data = Data(#"{"paneID":{"raw":"\#(paneID.raw.uuidString)"}}"#.utf8)
    let request = try JSONDecoder().decode(IPC.PaneAttachStreamRequest.self, from: data)
    #expect(request == IPC.PaneAttachStreamRequest(paneID: paneID))

    let full = IPC.PaneAttachStreamRequest(paneID: paneID, scrollbackRows: 200, coalesceMillis: 30)
    #expect(
      try JSONDecoder().decode(IPC.PaneAttachStreamRequest.self, from: JSONEncoder().encode(full)) == full)
  }

  @Test
  func requestHeadNamesAnUnknownMethod() throws {
    let data = Data(#"{"id":"r1","method":"pane.teleport","params":{}}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(IPC.Request.self, from: data) }
    let head = try JSONDecoder().decode(IPC.RequestHead.self, from: data)
    #expect(head == IPC.RequestHead(id: "r1", method: "pane.teleport"))
    #expect(head.unknownMethodError == .unknownMethod("pane.teleport"))
  }

  @Test
  func requestHeadOfAKnownMethodIsNotUnknown() throws {
    let head = try JSONDecoder().decode(
      IPC.RequestHead.self, from: Data(#"{"id":"r2","method":"system.ping","params":7}"#.utf8))
    #expect(head.unknownMethodError == nil)
    let noMethod = try JSONDecoder().decode(IPC.RequestHead.self, from: Data(#"{"id":"r3","method":5}"#.utf8))
    #expect(noMethod.method == nil)
    #expect(noMethod.unknownMethodError == nil)
  }
}
