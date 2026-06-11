import Foundation

/// `developer` sub-tree of `settings.json` (v2). Reserved slot for T3 (Developer pane) content.
/// In T1 this only carries a CLI install bookkeeping sub-struct with a single timestamp field so
/// T3 can extend it without a schema version bump.
public nonisolated struct DeveloperSettings: Equatable, Codable, Sendable {
  public var cli: DeveloperCLISettings

  public init(cli: DeveloperCLISettings = .init()) {
    self.cli = cli
  }

  public static let `default` = DeveloperSettings()

  private enum CodingKeys: String, CodingKey { case cli }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.cli = try container.decodeIfPresent(DeveloperCLISettings.self, forKey: .cli) ?? .init()
  }
}

public nonisolated struct DeveloperCLISettings: Equatable, Codable, Sendable {
  /// Timestamp of the most recent `codans` install attempt, successful or not. T3 uses it to pace
  /// retries and to label the last-attempt timestamp in the Developer pane.
  public var lastInstallAttemptAt: Date?

  public init(lastInstallAttemptAt: Date? = nil) {
    self.lastInstallAttemptAt = lastInstallAttemptAt
  }

  private enum CodingKeys: String, CodingKey { case lastInstallAttemptAt }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.lastInstallAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastInstallAttemptAt)
  }
}
