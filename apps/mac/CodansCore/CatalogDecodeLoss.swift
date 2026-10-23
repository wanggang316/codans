import Foundation

/// Counts the records a tolerant catalog decode dropped. A Tab that does
/// not decode is skipped instead of failing the whole catalog; a Pane
/// whose Tabs all dropped goes with its split-tree leaf. The loader reads
/// the counts after decoding to gate the session reaper and the unread
/// sweep: a dropped Tab's session must not be reaped as an orphan.
///
/// Attach one instance to the decoder (`attach(to:)`); the model types
/// find it through `decoder.userInfo`. Without a collector the decode is
/// still tolerant, only uncounted.
public nonisolated final class CatalogDecodeLoss: @unchecked Sendable {
  public static let userInfoKey = CodingUserInfoKey(rawValue: "com.gumpw.codans.catalog-decode-loss")!

  private let lock = NSLock()
  private var tabs = 0
  private var panes = 0

  public init() {}

  /// Tabs skipped because their record did not decode.
  public var droppedTabs: Int { lock.withLock { tabs } }
  /// Panes removed because every one of their Tabs dropped.
  public var droppedPanes: Int { lock.withLock { panes } }
  public var isEmpty: Bool { lock.withLock { tabs == 0 && panes == 0 } }

  public func recordDroppedTab() { lock.withLock { tabs += 1 } }
  public func recordDroppedPane() { lock.withLock { panes += 1 } }

  public func attach(to decoder: JSONDecoder) {
    decoder.userInfo[Self.userInfoKey] = self
  }

  /// The collector the loader attached, if any.
  public static func collector(in decoder: Decoder) -> CatalogDecodeLoss? {
    decoder.userInfo[userInfoKey] as? CatalogDecodeLoss
  }
}

/// Decodes any JSON value and keeps nothing. Decoding one from an unkeyed
/// container advances past an element that failed to decode as its real
/// type — `JSONDecoder` leaves the index on the element after a failure.
nonisolated struct DecodedSkip: Decodable {
  init(from decoder: Decoder) throws {}
}
