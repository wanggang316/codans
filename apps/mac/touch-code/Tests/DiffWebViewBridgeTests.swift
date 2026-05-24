import Foundation
import Testing

@testable import TouchCode

@MainActor
struct DiffWebViewBridgeTests {

  // MARK: - Outbound

  @Test
  func encodeRenderRoundTripsDocumentFiles() throws {
    let doc = DiffDocument(
      files: [
        DiffFile(oldPath: "a.swift", newPath: "a.swift", oldContents: "old", newContents: "new")
      ],
      title: "doc-1"
    )
    let json = try DiffWebViewBridge.encodeRender(doc, configuration: .init())
    let decoded = try anyJSON(from: json)
    #expect(decoded["protocolVersion"] as? Int == 1)
    #expect(decoded["type"] as? String == "renderDocument")
    let payload = try #require(decoded["payload"] as? [String: Any])
    let document = try #require(payload["document"] as? [String: Any])
    #expect(document["identifier"] as? String == "doc-1")
    let files = try #require(document["files"] as? [[String: Any]])
    #expect(files.count == 1)
    #expect(files[0]["oldContents"] as? String == "old")
    #expect(files[0]["newContents"] as? String == "new")
  }

  @Test
  func encodeSetOptionsCarriesAllDefaults() throws {
    let json = try DiffWebViewBridge.encodeSetOptions(.init())
    let decoded = try anyJSON(from: json)
    #expect(decoded["type"] as? String == "updateConfiguration")
    let payload = try #require(decoded["payload"] as? [String: Any])
    #expect(payload["diffStyle"] as? String == "unified")
    #expect(payload["diffIndicators"] as? String == "bars")
    #expect(payload["showsLineNumbers"] as? Bool == true)
    #expect(payload["showsChangeBackgrounds"] as? Bool == true)
    #expect(payload["wrapsLines"] as? Bool == false)
    #expect(payload["showsFileHeaders"] as? Bool == true)
    #expect(payload["inlineChangeStyle"] as? String == "wordAlt")
    #expect(payload["allowsSelection"] as? Bool == true)
  }

  // MARK: - Inbound

  @Test
  func decodeReadyEventMapsToDidFinishInitialLoad() throws {
    let json = #"{"protocolVersion":1,"id":"evt-1","type":"ready","payload":{"rendererVersion":"0.1.0"}}"#
    let event = try DiffWebViewBridge.decodeEvent(json)
    #expect(event == .didFinishInitialLoad)
  }

  @Test
  func decodeRenderStateChangedRenderedReportsFileCount() throws {
    let json = #"""
      {"protocolVersion":1,"id":"evt-2","type":"renderStateChanged","payload":{"state":"rendered","documentIdentifier":"d","summary":{"fileCount":3}}}
      """#
    let event = try DiffWebViewBridge.decodeEvent(json)
    #expect(event == .didRender(fileCount: 3))
  }

  @Test
  func decodeLineActivatedReportsLineNumber() throws {
    let json = #"""
      {"protocolVersion":1,"id":"evt-3","type":"lineActivated","payload":{"fileIndex":0,"oldPath":"a.swift","newPath":"a.swift","side":"new","number":42,"kind":"addition"}}
      """#
    let event = try DiffWebViewBridge.decodeEvent(json)
    #expect(event == .didClickLine(fileIndex: 0, lineNumber: 42))
  }

  @Test
  func decodeSelectionChangedWithRangeReportsSelection() throws {
    let json = #"""
      {"protocolVersion":1,"id":"evt-4","type":"selectionChanged","payload":{"selection":{"fileIndex":2,"start":{"side":"new","number":10},"end":{"side":"new","number":15}}}}
      """#
    let event = try DiffWebViewBridge.decodeEvent(json)
    #expect(
      event
        == .didChangeSelection(
          SelectionRange(fileIndex: 2, start: 10, end: 15, side: .additions)))
  }

  @Test
  func decodeSelectionChangedWithNullClearsSelection() throws {
    let json = #"""
      {"protocolVersion":1,"id":"evt-5","type":"selectionChanged","payload":{"selection":null}}
      """#
    let event = try DiffWebViewBridge.decodeEvent(json)
    #expect(event == .didChangeSelection(nil))
  }

  @Test
  func encodeRenderProducesByteIdenticalJSONForEqualInputs() throws {
    // Pinning test for the deterministic-identifier fix: re-encoding the
    // same `DiffDocument` must yield byte-identical JSON, otherwise the
    // Coordinator's send-cache (which keys on the script string) can't
    // dedupe duplicate `renderDocument` envelopes from `updateNSView`.
    let doc = DiffDocument(
      files: [
        DiffFile(oldPath: "a.swift", newPath: "a.swift", oldContents: "old", newContents: "new")
      ],
      title: "doc-1"
    )
    let a = try DiffWebViewBridge.encodeRender(doc, configuration: .init())
    let b = try DiffWebViewBridge.encodeRender(doc, configuration: .init())
    #expect(a == b)

    // Same with a `nil` title — falls through to the file-id-derived
    // identifier rather than minting a fresh UUID per call.
    let untitled = DiffDocument(
      files: [
        DiffFile(oldPath: "x", newPath: "x", oldContents: "1", newContents: "2")
      ]
    )
    let c = try DiffWebViewBridge.encodeRender(untitled, configuration: .init())
    let d = try DiffWebViewBridge.encodeRender(untitled, configuration: .init())
    #expect(c == d)
  }

  @Test
  func encodeRenderWithFallbackPatchRoundTrips() throws {
    let doc = DiffDocument(
      files: [],
      title: "rename.swift",
      fallbackPatch: "diff --git a/a b/b\nrename from a\nrename to b\n"
    )
    let json = try DiffWebViewBridge.encodeRender(doc, configuration: .init())
    let decoded = try anyJSON(from: json)
    let payload = try #require(decoded["payload"] as? [String: Any])
    let document = try #require(payload["document"] as? [String: Any])
    #expect(document["patch"] as? String == "diff --git a/a b/b\nrename from a\nrename to b\n")
  }

  @Test
  func decodeRenderStateChangedFailedSurfacesDidFail() throws {
    let json = #"""
      {"protocolVersion":1,"id":"evt-7","type":"renderStateChanged","payload":{"state":"failed","documentIdentifier":"d","error":{"code":"shiki_failed","message":"highlight error"}}}
      """#
    let event = try DiffWebViewBridge.decodeEvent(json)
    if case .didFail(let code, let message) = event {
      #expect(code == "shiki_failed")
      #expect(message == "highlight error")
    } else {
      Issue.record("expected .didFail, got \(event)")
    }
  }

  @Test
  func decodeSelectionChangedWithMixedSidesCollapsesToBoth() throws {
    let json = #"""
      {"protocolVersion":1,"id":"evt-8","type":"selectionChanged","payload":{"selection":{"fileIndex":1,"start":{"side":"old","number":3},"end":{"side":"new","number":7}}}}
      """#
    let event = try DiffWebViewBridge.decodeEvent(json)
    #expect(
      event
        == .didChangeSelection(
          SelectionRange(fileIndex: 1, start: 3, end: 7, side: .both)))
  }

  @Test
  func decodeMalformedJSONSurfacesDecodeFailed() throws {
    // Garbage in: must not throw out of `decodeEvent` because the
    // Coordinator's catch-all relies on the throw-and-catch path; this
    // test pins that contract by asserting `.decodeEvent` does throw,
    // which the Coordinator then wraps as `.didFail(code: "decode_failed")`.
    #expect(throws: (any Error).self) {
      _ = try DiffWebViewBridge.decodeEvent("{not json")
    }
  }

  @Test
  func decodeWrongProtocolVersionSurfacesProtocolMismatch() throws {
    let json = #"{"protocolVersion":2,"id":"evt-6","type":"ready","payload":{}}"#
    let event = try DiffWebViewBridge.decodeEvent(json)
    if case .didFail(let code, _) = event {
      #expect(code == "protocol_mismatch")
    } else {
      Issue.record("expected .didFail(code: protocol_mismatch), got \(event)")
    }
  }

  // MARK: - Helpers

  private func anyJSON(from string: String) throws -> [String: Any] {
    let data = try #require(string.data(using: .utf8))
    let raw = try JSONSerialization.jsonObject(with: data)
    return try #require(raw as? [String: Any])
  }
}
