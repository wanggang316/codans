import Foundation
import Testing

@testable import CodansCore

struct SessionEpochTests {
  // MARK: - SessionEpoch.current()

  /// The test process runs inside a normal login/audit session, so
  /// `current()` resolves to a positive asid string. `nil` is tolerated
  /// (a headless runner with no audit session) — the reaper treats `nil`
  /// as "skip epoch logic", the safe default. What must never happen is
  /// `current()` handing back the `AU_DEFAUDITSID` sentinel ("0") as a
  /// usable value, which would make every comparison spurious.
  @Test
  func currentResolvesToPositiveAsidOrNil() {
    if let epoch = SessionEpoch.current() {
      let value = Int(epoch)
      #expect(value != nil)
      #expect((value ?? 0) > 0)
    }
  }

  // MARK: - SessionEpoch.isStranded

  /// An unknown epoch on either side disables the comparison: a `nil`
  /// `currentEpoch` means our vantage is untrustworthy, and a `nil`
  /// `rowEpoch` means the row predates the field. Both must read as
  /// "not stranded" so neither a degraded launch nor an upgrade recycles
  /// healthy daemons.
  @Test
  func isStrandedFalseWhenEitherEpochUnknown() {
    #expect(SessionEpoch.isStranded(rowEpoch: nil, currentEpoch: "100") == false)
    #expect(SessionEpoch.isStranded(rowEpoch: "100", currentEpoch: nil) == false)
    #expect(SessionEpoch.isStranded(rowEpoch: nil, currentEpoch: nil) == false)
  }

  /// With both epochs known, a mismatch means the daemon outlived its
  /// session and a match means it is still in the live one.
  @Test
  func isStrandedTracksEpochMismatch() {
    #expect(SessionEpoch.isStranded(rowEpoch: "100", currentEpoch: "200") == true)
    #expect(SessionEpoch.isStranded(rowEpoch: "200", currentEpoch: "200") == false)
  }

  // MARK: - Session codable backward-compat

  private func makeSession(epoch: String?) -> Session {
    Session(
      paneID: PaneID(),
      socketPath: "/tmp/zmx/pane.sock",
      pid: 1234,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastAttachedAt: Date(timeIntervalSince1970: 1_700_000_000),
      command: ["/bin/zsh", "-l"],
      cwd: "/tmp",
      zmxVersion: "0.1.0",
      sessionEpoch: epoch
    )
  }

  /// A session row written before `sessionEpoch` existed must decode with
  /// the field defaulting to `nil` rather than failing the whole load.
  /// Built by encoding a stamped row and removing the key via
  /// `JSONSerialization` so the strip stays agnostic to the encoder's
  /// pretty-printed / sorted-keys formatting.
  @Test
  func sessionWithoutEpochDecodesToNil() throws {
    let encoded = try JSONEncoder.touchCodeDefault.encode(makeSession(epoch: "107981"))
    var object = try #require(
      try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "sessionEpoch")
    let stripped = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder.touchCodeDefault.decode(Session.self, from: stripped)
    #expect(decoded.sessionEpoch == nil)
  }

  /// A stamped row round-trips through the canonical encoder pair.
  @Test
  func sessionEpochRoundTrips() throws {
    let original = makeSession(epoch: "107981")
    let encoded = try JSONEncoder.touchCodeDefault.encode(original)
    let decoded = try JSONDecoder.touchCodeDefault.decode(Session.self, from: encoded)
    #expect(decoded == original)
    #expect(decoded.sessionEpoch == "107981")
  }
}
