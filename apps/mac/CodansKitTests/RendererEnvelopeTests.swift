import CodansIPC
import Foundation
import Testing

@testable import CodansKit

/// `--json` output is one envelope per command: `schemaVersion` plus
/// exactly one of `data` / `error`. Consumers pin these shapes.
struct RendererEnvelopeTests {
  private struct Sample: Encodable, CustomStringConvertible {
    let id: String
    let count: Int
    var description: String { "sample \(id)" }
  }

  @Test
  func successEnvelopeCarriesSchemaVersionAndData() throws {
    let json = try Renderer.$context.withValue(RenderContext(command: "pane.send")) {
      var out = ""
      try Renderer.emit(Sample(id: "p1", count: 2), mode: .json) { out = $0 }
      return out
    }
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(object["schemaVersion"] as? String == "codans.cli.pane.send.v1")
    let data = try #require(object["data"] as? [String: Any])
    #expect(data["id"] as? String == "p1")
    #expect(data["count"] as? Int == 2)
    #expect(object["error"] == nil)
  }

  @Test
  func objectEnvelopeMatchesTheTypedOne() throws {
    let json = try Renderer.$context.withValue(RenderContext(command: "status")) {
      var out = ""
      try Renderer.emitObject(["server": "codans", "uptimeSeconds": 1.5], mode: .json, sink: { out = $0 })
      return out
    }
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(object["schemaVersion"] as? String == "codans.cli.status.v1")
    let data = try #require(object["data"] as? [String: Any])
    #expect(data["server"] as? String == "codans")
  }

  @Test
  func errorEnvelopeCarriesCodeMessageHintAndDetails() throws {
    let payload = CLIErrorPayload(
      code: .notFound, message: "pane not found: p9", hint: "run tree", details: ["kind": "pane", "id": "p9"])
    let json = try Renderer.$context.withValue(RenderContext(command: "pane.focus")) {
      var out = ""
      try Renderer.emitError(payload, mode: .json) { out = $0 }
      return out
    }
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(object["schemaVersion"] as? String == "codans.cli.pane.focus.v1")
    #expect(object["data"] == nil)
    let error = try #require(object["error"] as? [String: Any])
    #expect(error["code"] as? String == "NOT_FOUND")
    #expect(error["message"] as? String == "pane not found: p9")
    #expect(error["hint"] as? String == "run tree")
    #expect((error["details"] as? [String: String]) == ["kind": "pane", "id": "p9"])
  }

  @Test
  func textModeIsUntouchedByTheEnvelope() throws {
    var out = ""
    try Renderer.emit(Sample(id: "p1", count: 2), mode: .text(useColor: false)) { out = $0 }
    #expect(out == "sample p1")
    var err = ""
    try Renderer.emitError(
      CLIErrorPayload(code: .conflict, message: "busy", hint: "wait"), mode: .text(useColor: false)
    ) { err = $0 }
    #expect(err == "error: busy\n  hint: wait")
  }

  @Test
  func everyExitCodeHasADefaultErrorCode() {
    // Pin the table so a new exit code forces a decision here.
    let expected: [CLIExitCode: CLIErrorCode] = [
      .userError: .invalidArgument, .notFound: .notFound, .conflict: .conflict,
      .unsupported: .unsupported, .overloaded: .overloaded, .versionMismatch: .versionMismatch,
      .noSocket: .appNotRunning, .requestTimeout: .requestTimeout, .launchTimeout: .launchTimeout,
      .socketPermissionDenied: .socketPermissionDenied, .socketUnusable: .socketUnusable,
      .wrongChannel: .wrongChannel, .internal: .internal,
    ]
    for (exit, code) in expected {
      #expect(CLIErrorCode.default(for: exit) == code, "\(exit)")
    }
  }
}
