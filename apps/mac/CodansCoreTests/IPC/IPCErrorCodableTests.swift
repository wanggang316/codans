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
    ]
    for variant in variants {
      let data = try JSONEncoder().encode(variant)
      let decoded = try JSONDecoder().decode(IPCError.self, from: data)
      #expect(decoded == variant, "\(variant) did not round-trip")
    }
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
