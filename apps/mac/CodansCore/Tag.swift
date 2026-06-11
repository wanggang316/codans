import Foundation

/// A user-assigned label that can be attached to any number of `Project`s.
/// Identified by stable `TagID`; `name` and `color` are mutable. The Codable
/// shape encodes the seven palette colors as their enum raw values so
/// `catalog.json` stays human-readable.
public nonisolated struct Tag: Equatable, Codable, Sendable, Identifiable {
  public var id: TagID
  public var name: String
  public var color: TagColor

  public init(id: TagID = TagID(), name: String, color: TagColor) {
    self.id = id
    self.name = name
    self.color = color
  }
}

/// Fixed palette matching the macOS Finder tag colors. We do not expose
/// arbitrary hex on purpose — see `docs/design-docs/project-tags.md` §4.3.
public nonisolated enum TagColor: String, Codable, CaseIterable, Sendable {
  case red, orange, yellow, green, blue, purple, grey
}

/// Drives sidebar visibility. Stored at `Catalog` top level (single window).
/// `.tags` carries an in-memory `Set<TagID>`; the Codable shape sorts the
/// IDs on encode so `git diff catalog.json` stays deterministic. An empty
/// set encodes as `.tags([])` but should be treated by callers as
/// equivalent to `.all` — `HierarchyManager.setActiveTagFilter` performs
/// that normalization.
public nonisolated enum TagFilter: Equatable, Sendable {
  case all
  case tags(Set<TagID>)
  case untagged
}

extension TagFilter: Codable {
  private enum Kind: String, Codable {
    case all, tags, untagged
  }

  private enum CodingKeys: String, CodingKey {
    case kind, tagIDs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    switch kind {
    case .all:
      self = .all
    case .untagged:
      self = .untagged
    case .tags:
      let ids = try container.decodeIfPresent([TagID].self, forKey: .tagIDs) ?? []
      self = .tags(Set(ids))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .all:
      try container.encode(Kind.all, forKey: .kind)
    case .untagged:
      try container.encode(Kind.untagged, forKey: .kind)
    case .tags(let ids):
      try container.encode(Kind.tags, forKey: .kind)
      let sorted = ids.sorted { $0.raw.uuidString < $1.raw.uuidString }
      try container.encode(sorted, forKey: .tagIDs)
    }
  }
}
