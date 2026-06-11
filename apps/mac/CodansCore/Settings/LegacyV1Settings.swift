import Foundation

/// Permissive Codable for the pre-v2 `settings.json`. Every field is optional — legacy
/// writers populated different subsets and we only carry forward what is still relevant.
///
/// Used by `SettingsMigration.load` to carry user data forward into v3. Not otherwise
/// consumed and never written back to disk.
public nonisolated struct LegacyV1Settings: Decodable, Sendable {
  public let version: Int?
  public let defaultEditorID: EditorID?

  public init(
    version: Int? = nil,
    defaultEditorID: EditorID? = nil
  ) {
    self.version = version
    self.defaultEditorID = defaultEditorID
  }

  private enum CodingKeys: String, CodingKey {
    case version, defaultEditorID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.version = try container.decodeIfPresent(Int.self, forKey: .version)
    self.defaultEditorID = try container.decodeIfPresent(EditorID.self, forKey: .defaultEditorID)
  }
}
