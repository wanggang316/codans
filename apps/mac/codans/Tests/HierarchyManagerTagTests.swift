import Foundation
import Testing
import CodansCore

@testable import Codans

/// Coverage for `HierarchyManager`'s tag CRUD + cascade rules + filter
/// normalization. The design treats `removeTag` as the
/// trickiest piece because it cascades through three independent buckets
/// (the tag list, every project's `tagIDs`, and `activeTagFilter`); this
/// suite locks each bucket separately so a future refactor can't silently
/// drop one.
@MainActor
struct HierarchyManagerTagTests {
  private func makeManager() -> (HierarchyManager, FakeHierarchyRuntime, CatalogStore) {
    let tempURL = FileManager.default.temporaryDirectory.appending(
      component: UUID().uuidString + ".json"
    )
    let runtime = FakeHierarchyRuntime()
    let store = CatalogStore(fileURL: tempURL)
    let manager = HierarchyManager(catalog: .default, store: store, runtime: runtime)
    return (manager, runtime, store)
  }

  @Test
  func createTagAppendsAndAssignsColor() {
    let (manager, _, _) = makeManager()
    let id = manager.createTag(name: "urgent", color: .red)
    #expect(manager.catalog.tags.count == 1)
    let tag = try? #require(manager.catalog.tags.first)
    #expect(tag?.id == id)
    #expect(tag?.name == "urgent")
    #expect(tag?.color == .red)
  }

  @Test
  func renameTagMutatesNameInPlace() {
    let (manager, _, _) = makeManager()
    let id = manager.createTag(name: "old", color: .blue)
    manager.renameTag(id, to: "new")
    #expect(manager.catalog.tags.first?.name == "new")
  }

  @Test
  func recolorTagMutatesColorInPlace() {
    let (manager, _, _) = makeManager()
    let id = manager.createTag(name: "t", color: .blue)
    manager.recolorTag(id, to: .green)
    #expect(manager.catalog.tags.first?.color == .green)
  }

  // MARK: - removeTag cascade

  @Test
  func removeTagStripsFromAllProjects() {
    let (manager, _, _) = makeManager()
    let p1 = manager.addProject(name: "p1", rootPath: "/p1", gitRoot: nil)
    let p2 = manager.addProject(name: "p2", rootPath: "/p2", gitRoot: nil)
    let p3 = manager.addProject(name: "p3", rootPath: "/p3", gitRoot: nil)
    let kept = manager.createTag(name: "kept", color: .blue)
    let dropped = manager.createTag(name: "dropped", color: .red)
    manager.setProjectTags(p1, tags: [kept, dropped])
    manager.setProjectTags(p2, tags: [dropped])
    manager.setProjectTags(p3, tags: [kept])

    manager.removeTag(dropped)

    #expect(manager.catalog.tags.map(\.id) == [kept])
    #expect(manager.catalog.projects.first(where: { $0.id == p1 })?.tagIDs == [kept])
    #expect(manager.catalog.projects.first(where: { $0.id == p2 })?.tagIDs.isEmpty == true)
    #expect(manager.catalog.projects.first(where: { $0.id == p3 })?.tagIDs == [kept])
  }

  @Test
  func removeTagDropsIDFromActiveFilter() {
    let (manager, _, _) = makeManager()
    let kept = manager.createTag(name: "kept", color: .blue)
    let dropped = manager.createTag(name: "dropped", color: .red)
    manager.setActiveTagFilter(.tags([kept, dropped]))

    manager.removeTag(dropped)

    #expect(manager.catalog.activeTagFilter == .tags([kept]))
  }

  @Test
  func removeTagResetsFilterToAllWhenLastIDDrops() {
    let (manager, _, _) = makeManager()
    let only = manager.createTag(name: "only", color: .blue)
    manager.setActiveTagFilter(.tags([only]))

    manager.removeTag(only)

    #expect(manager.catalog.tags.isEmpty)
    #expect(manager.catalog.activeTagFilter == .all)
  }

  @Test
  func removeTagIsIdempotentForUnknownID() {
    let (manager, _, _) = makeManager()
    let id = manager.createTag(name: "real", color: .blue)
    let stranger = TagID()
    manager.removeTag(stranger)
    // The real tag is untouched; the second remove on the real id behaves
    // normally.
    #expect(manager.catalog.tags.first?.id == id)
    manager.removeTag(id)
    #expect(manager.catalog.tags.isEmpty)
  }

  @Test
  func removeTagDoesNotTouchProjectsThatNeverCarriedIt() {
    let (manager, _, _) = makeManager()
    let p1 = manager.addProject(name: "p1", rootPath: "/p1", gitRoot: nil)
    let kept = manager.createTag(name: "kept", color: .blue)
    let dropped = manager.createTag(name: "dropped", color: .red)
    manager.setProjectTags(p1, tags: [kept])

    manager.removeTag(dropped)

    #expect(manager.catalog.projects.first(where: { $0.id == p1 })?.tagIDs == [kept])
  }

  // MARK: - setActiveTagFilter normalization

  @Test
  func setActiveTagFilterEmptyTagsNormalizesToAll() {
    let (manager, _, _) = makeManager()
    manager.setActiveTagFilter(.tags([]))
    #expect(manager.catalog.activeTagFilter == .all)
  }

  @Test
  func setActiveTagFilterRoundTripsAll() {
    let (manager, _, _) = makeManager()
    manager.setActiveTagFilter(.untagged)
    manager.setActiveTagFilter(.all)
    #expect(manager.catalog.activeTagFilter == .all)
  }

  @Test
  func setActiveTagFilterUntaggedRoundTrips() {
    let (manager, _, _) = makeManager()
    manager.setActiveTagFilter(.untagged)
    #expect(manager.catalog.activeTagFilter == .untagged)
  }

  // MARK: - setProjectTags

  @Test
  func setProjectTagsReplacesEntireSet() {
    let (manager, _, _) = makeManager()
    let p = manager.addProject(name: "p", rootPath: "/p", gitRoot: nil)
    let a = manager.createTag(name: "a", color: .blue)
    let b = manager.createTag(name: "b", color: .red)
    let c = manager.createTag(name: "c", color: .green)
    manager.setProjectTags(p, tags: [a, b])
    manager.setProjectTags(p, tags: [c])
    #expect(manager.catalog.projects.first?.tagIDs == [c])
  }

  @Test
  func setProjectTagsUnknownProjectIsSilentNoOp() {
    let (manager, _, _) = makeManager()
    let stranger = ProjectID()
    let tag = manager.createTag(name: "t", color: .blue)
    manager.setProjectTags(stranger, tags: [tag])
    // No project to mutate, no crash; tag list unchanged.
    #expect(manager.catalog.tags.first?.id == tag)
  }
}
