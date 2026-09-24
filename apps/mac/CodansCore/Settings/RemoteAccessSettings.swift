import Foundation

/// `remoteAccess` sub-tree of `settings.json`: the LAN gateway the iOS
/// companion connects to. Paired devices live in `remote-devices.json` and
/// their keys in the Keychain, never here.
public nonisolated struct RemoteAccessSettings: Equatable, Codable, Sendable {
  /// Whether the gateway listens and advertises. Off by default: a user who
  /// never opts in gets no open port and no Bonjour advertisement.
  public var enabled: Bool

  public init(enabled: Bool = false) {
    self.enabled = enabled
  }

  public static let `default` = RemoteAccessSettings()

  private enum CodingKeys: String, CodingKey { case enabled }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
  }
}
