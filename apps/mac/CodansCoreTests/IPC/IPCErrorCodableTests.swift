import Foundation
import Testing

@testable import CodansIPC

struct IPCErrorCodableTests {
  @Test
  func everyVariantRoundTrips() throws {
    let variants: [IPCError] = [
      .unknownMethod("foo.bar"),
      .invalidParams(message: "missing id", path: ["params", "id"]),
      .notFound(kind: "pane", id: "uuid"),
      .conflict(reason: "directory exists"),
      .unsupported(reason: "not a git project"),
      .internal("bug: unreachable"),
      .overloaded,
      .versionMismatch(client: "0.1.0", server: "0.2.0"),
      .invalidFrame(reason: "frame too large"),
      .domain(code: "PANE_BUSY", message: "pane p3 belongs to run abc", hint: "cancel that run first"),
      .domain(code: "RUN_NOT_FOUND", message: "no such run", hint: nil),
    ]
    for variant in variants {
      let data = try JSONEncoder().encode(variant)
      let decoded = try JSONDecoder().decode(IPCError.self, from: data)
      #expect(decoded == variant, "\(variant) did not round-trip")
    }
  }

  @Test
  func domainWireShapeCarriesTheFeatureCodeBesideTheDiscriminator() throws {
    let error = IPCError.domain(code: "WORKFLOW_INVALID", message: "2 errors", hint: "run validate")
    let data = try JSONEncoder().encode(error)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["code"] as? String == "domain")
    #expect(object["domainCode"] as? String == "WORKFLOW_INVALID")
    #expect(object["message"] as? String == "2 errors")
    #expect(object["hint"] as? String == "run validate")
    #expect(error.code == "domain")
    #expect(error.message == "2 errors")
    #expect(error.displayMessage == "2 errors")

    let withoutHint = try JSONEncoder().encode(IPCError.domain(code: "X", message: "m", hint: nil))
    let bare = try #require(JSONSerialization.jsonObject(with: withoutHint) as? [String: Any])
    #expect(bare["hint"] == nil)
  }

  @Test
  func codeStringsAreStable() {
    #expect(IPCError.unknownMethod("").code == "unknownMethod")
    #expect(IPCError.invalidParams(message: "", path: nil).code == "invalidParams")
    #expect(IPCError.overloaded.code == "overloaded")
    #expect(IPCError.versionMismatch(client: "", server: "").code == "versionMismatch")
    #expect(IPCError.invalidFrame(reason: "").code == "invalidFrame")
  }

  @Test
  func decoderRejectsUnknownCode() throws {
    let payload = Data(#"{"code":"nebula","message":"huh"}"#.utf8)
    #expect(throws: IPCError.DecodingIssue.unknownCode("nebula")) {
      _ = try JSONDecoder().decode(IPCError.self, from: payload)
    }
  }
}
