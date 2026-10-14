import Foundation

/// `remoteAccess` sub-tree of `settings.json`: the LAN gateway the iOS
/// companion connects to. Paired devices live in `remote-devices.json` and
/// their keys in the Keychain, never here.
public nonisolated struct RemoteAccessSettings: Equatable, Codable, Sendable {
  /// Whether the gateway listens and advertises. Off by default: a user who
  /// never opts in gets no open port and no Bonjour advertisement.
  public var enabled: Bool
  /// Whether paired devices may also reach the gateway from outside the LAN
  /// through the relay. Off by default, and only in effect while `enabled`.
  public var allowsRelay: Bool

  public init(enabled: Bool = false, allowsRelay: Bool = false) {
    self.enabled = enabled
    self.allowsRelay = allowsRelay
  }

  public static let `default` = RemoteAccessSettings()

  private enum CodingKeys: String, CodingKey { case enabled, allowsRelay }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    self.allowsRelay = try container.decodeIfPresent(Bool.self, forKey: .allowsRelay) ?? false
  }
}
