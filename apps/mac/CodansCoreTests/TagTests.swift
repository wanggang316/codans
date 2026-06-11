import Foundation
import Testing

@testable import CodansCore

/// Exercises the `Tag`, `TagColor`, `TagFilter` value types — pure
/// serialization round-trips. Consumers (Project.tagIDs, Catalog.tags,
/// Catalog.activeTagFilter) are added in a later milestone.
struct TagTests {
  @Test
  func tagRoundTrip() throws {
    let tag = CodansCore.Tag(name: "client-acme", color: .blue)
    let data = try JSONEncoder().encode(tag)
    let decoded = try JSONDecoder().decode(CodansCore.Tag.self, from: data)
    #expect(decoded == tag)
  }

  @Test
  func everyTagColorRoundTrips() throws {
    for color in TagColor.allCases {
      let data = try JSONEncoder().encode(color)
      let decoded = try JSONDecoder().decode(TagColor.self, from: data)
      #expect(decoded == color)
    }
  }

  @Test
  func tagColorEncodesAsRawValueString() throws {
    let data = try JSONEncoder().encode(TagColor.purple)
    let string = String(data: data, encoding: .utf8)
    #expect(string == "\"purple\"")
  }

  @Test
  func filterAllRoundTrips() throws {
    let filter = TagFilter.all
    let data = try JSONEncoder().encode(filter)
    let decoded = try JSONDecoder().decode(TagFilter.self, from: data)
    #expect(decoded == filter)
  }

  @Test
  func filterUntaggedRoundTrips() throws {
    let filter = TagFilter.untagged
    let data = try JSONEncoder().encode(filter)
    let decoded = try JSONDecoder().decode(TagFilter.self, from: data)
    #expect(decoded == filter)
  }

  @Test
  func filterTagsRoundTrips() throws {
    let ids: Set<TagID> = [TagID(), TagID(), TagID()]
    let filter = TagFilter.tags(ids)
    let data = try JSONEncoder().encode(filter)
    let decoded = try JSONDecoder().decode(TagFilter.self, from: data)
    #expect(decoded == filter)
  }

  @Test
  func filterTagsEncodesIDsInSortedOrder() throws {
    // Set has no inherent ordering. The encoder sorts by raw UUID string so
    // `git diff catalog.json` is stable. Decode the encoded form back into
    // a JSON object and assert the `tagIDs` array is sorted by `raw`.
    let a = TagID()
    let b = TagID()
    let c = TagID()
    let filter = TagFilter.tags([a, b, c])
    let data = try JSONEncoder().encode(filter)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let tagIDs = try #require(object?["tagIDs"] as? [[String: Any]])
    let raws = tagIDs.compactMap { $0["raw"] as? String }
    #expect(raws == raws.sorted())
  }

  @Test
  func filterTagsWithEmptySetEncodes() throws {
    // An empty .tags set is technically representable; HierarchyManager
    // normalizes it to .all in the runtime, but the type itself must encode
    // and decode without losing the case distinction.
    let filter = TagFilter.tags([])
    let data = try JSONEncoder().encode(filter)
    let decoded = try JSONDecoder().decode(TagFilter.self, from: data)
    #expect(decoded == filter)
  }

  @Test
  func filterEncodingShapeIsKindKeyed() throws {
    // The on-disk shape is { "kind": "all" | "tags" | "untagged",
    // "tagIDs"?: [...] }. Lock the surface so consumers reading
    // catalog.json by hand see a discriminated union, not a Swift-only
    // enum encoding.
    let filter = TagFilter.untagged
    let data = try JSONEncoder().encode(filter)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["kind"] as? String == "untagged")
    #expect(object?["tagIDs"] == nil)
  }
}
