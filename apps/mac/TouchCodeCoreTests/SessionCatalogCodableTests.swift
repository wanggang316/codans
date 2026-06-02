import Foundation
import Testing

@testable import TouchCodeCore

@MainActor
struct SessionCatalogCodableTests {
  /// Guards the M6.T6.5 forward-compatibility hook: a v1 catalog written
  /// before the `agents` field existed must still decode without error,
  /// defaulting to an empty agents map. The custom `init(from:)` uses
  /// `decodeIfPresent`; if a future contributor swaps it back to plain
  /// `decode`, this test fails loudly.
  @Test
  func agentsFieldIsOptionalOnDecode() throws {
    // A v1 catalog file would have had `version` and `sessions` only;
    // the `agents` key did not exist. Hand-rolling the minimal JSON
    // because round-tripping through `JSONEncoder` would always emit
    // the key — defeating the test.
    let v1Payload = #"""
      {
        "version": 1,
        "sessions": {}
      }
      """#
    let data = Data(v1Payload.utf8)

    let catalog = try JSONDecoder().decode(SessionCatalog.self, from: data)

    #expect(catalog.version == 1)
    #expect(catalog.sessions.isEmpty)
    #expect(catalog.agents.isEmpty)
  }

  /// Verifies the agents field round-trips when populated, using the
  /// project's canonical encoder pair to avoid drift on encoding-strategy
  /// changes elsewhere. If the custom `encode(to:)` regresses to omitting
  /// `agents` for empty maps, the round-trip assertion still passes for a
  /// non-empty value — so we also assert the key is present in raw JSON
  /// for an empty-but-encoded catalog.
  @Test
  func agentsRoundTripWhenPopulated() throws {
    let paneID = PaneID()
    let record = PersistedAgentRecord(
      paneID: paneID,
      kindRaw: "claude-code",
      stateRaw: "waitingForInput",
      pid: 4242,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let catalog = SessionCatalog(
      version: SessionCatalog.currentVersion,
      sessions: [:],
      agents: [paneID.raw.uuidString: record]
    )

    let encoded = try JSONEncoder.touchCodeDefault.encode(catalog)
    let decoded = try JSONDecoder.touchCodeDefault.decode(SessionCatalog.self, from: encoded)

    #expect(decoded == catalog)
    #expect(decoded.agents[paneID.raw.uuidString]?.kindRaw == "claude-code")
    #expect(decoded.agents[paneID.raw.uuidString]?.pid == 4242)

    // Also confirm the encoded JSON includes the `agents` key even when
    // the agents map is empty — symmetry with the v1 decode test above.
    let emptyCatalog = SessionCatalog(version: SessionCatalog.currentVersion)
    let emptyEncoded = try JSONEncoder.touchCodeDefault.encode(emptyCatalog)
    let raw = try #require(String(data: emptyEncoded, encoding: .utf8))
    #expect(raw.contains("\"agents\""))
  }

  /// Forward-compat for the agent map itself: an unknown `kindRaw` /
  /// `stateRaw` value (e.g. a future build's enum case) must decode as
  /// a `PersistedAgentRecord` rather than failing the whole catalog
  /// load. The drop-on-restore happens at the seed site, not at decode.
  /// Built by encoding a known record and string-mutating the raw values
  /// so the shape stays in sync with the canonical encoder.
  @Test
  func unknownAgentEnumRawsDecodeWithoutFailing() throws {
    let paneID = PaneID()
    let known = PersistedAgentRecord(
      paneID: paneID,
      kindRaw: "claude-code",
      stateRaw: "idle",
      pid: 99,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let baseline = SessionCatalog(
      version: SessionCatalog.currentVersion,
      sessions: [:],
      agents: [paneID.raw.uuidString: known]
    )
    let encoded = try JSONEncoder.touchCodeDefault.encode(baseline)
    var json = try #require(String(data: encoded, encoding: .utf8))
    json = json.replacingOccurrences(of: "claude-code", with: "future-agent-not-in-this-build")
    json = json.replacingOccurrences(of: "\"idle\"", with: "\"waitingForUnknownThing\"")
    let mutated = try #require(json.data(using: .utf8))

    let catalog = try JSONDecoder.touchCodeDefault.decode(SessionCatalog.self, from: mutated)

    #expect(catalog.agents.count == 1)
    let record = try #require(catalog.agents[paneID.raw.uuidString])
    #expect(record.kindRaw == "future-agent-not-in-this-build")
    #expect(record.stateRaw == "waitingForUnknownThing")
  }
}
