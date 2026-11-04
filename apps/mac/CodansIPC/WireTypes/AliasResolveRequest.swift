import Foundation
import CodansCore

extension IPC {
  /// Params for `hierarchy.resolveAlias`. The CLI's `AliasResolver` sends
  /// one of these for every non-UUID identifier (current/index/label/glob);
  /// pure UUIDs are resolved locally and do not round-trip.
  public struct AliasResolveRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
      case project, worktree, tab, pane, tag
    }

    public let kind: Kind
    public let value: String
    public let contextPaneID: PaneID?
    /// `HostSelector` string (`0` or a Host UUID) that limits Project
    /// resolution to one Host; nil does not filter. Other kinds ignore it.
    public let hostID: String?

    public init(kind: Kind, value: String, contextPaneID: PaneID? = nil, hostID: String? = nil) {
      self.kind = kind
      self.value = value
      self.contextPaneID = contextPaneID
      self.hostID = hostID
    }
  }

  /// Result for `hierarchy.resolveAlias`. `disambiguations` is non-empty
  /// only when the caller's verb is list-shaped and tolerates multiple hits.
  public struct AliasResolveResult: Codable, Equatable, Sendable {
    public let kind: AliasResolveRequest.Kind
    public let id: UUID
    public let disambiguations: [UUID]?

    public init(kind: AliasResolveRequest.Kind, id: UUID, disambiguations: [UUID]? = nil) {
      self.kind = kind
      self.id = id
      self.disambiguations = disambiguations
    }
  }
}
