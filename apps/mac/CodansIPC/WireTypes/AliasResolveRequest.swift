import CodansCore
import Foundation

extension IPC {
  /// Params for `hierarchy.resolveAlias`. The CLI's `AliasResolver` sends
  /// one of these for every Pane / Tab / Content reference (ids included,
  /// since the server converts between the three levels) and for every
  /// non-UUID project / worktree / tag reference. `contextContentID`
  /// carries the caller's session (`CODANS_CONTENT_ID`).
  public struct AliasResolveRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
      case project, worktree, pane, tab, content, tag
    }

    public let kind: Kind
    public let value: String
    public let contextContentID: ContentID?

    public init(kind: Kind, value: String, contextContentID: ContentID? = nil) {
      self.kind = kind
      self.value = value
      self.contextContentID = contextContentID
    }
  }

  /// Result for `hierarchy.resolveAlias`. `id` is at the requested `kind`;
  /// `matched` is the level the value itself named (`pane`, `tab`, or
  /// `content`) before conversion, so a verb that must not convert (`pane
  /// close` given a Tab) can refuse. `disambiguations` is non-empty only
  /// when the caller's verb is list-shaped and tolerates multiple hits.
  public struct AliasResolveResult: Codable, Equatable, Sendable {
    public let kind: AliasResolveRequest.Kind
    public let id: UUID
    public let matched: AliasResolveRequest.Kind?
    public let disambiguations: [UUID]?

    public init(
      kind: AliasResolveRequest.Kind,
      id: UUID,
      matched: AliasResolveRequest.Kind? = nil,
      disambiguations: [UUID]? = nil
    ) {
      self.kind = kind
      self.id = id
      self.matched = matched
      self.disambiguations = disambiguations
    }
  }
}
