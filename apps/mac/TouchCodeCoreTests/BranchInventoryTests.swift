import Foundation
import Testing

@testable import TouchCodeCore

struct BranchInventoryTests {
  @Test
  func branchRefEqualityIsValueBased() {
    let a = BranchRef(shortName: "main", isRemote: false, upstream: "origin/main")
    let b = BranchRef(shortName: "main", isRemote: false, upstream: "origin/main")
    #expect(a == b)

    #expect(a != BranchRef(shortName: "dev", isRemote: false, upstream: "origin/main"))
    #expect(a != BranchRef(shortName: "main", isRemote: true, upstream: "origin/main"))
    #expect(a != BranchRef(shortName: "main", isRemote: false, upstream: nil))
  }

  @Test
  func detachedHeadIsRepresentedByNilCurrent() {
    let inventory = BranchInventory(
      current: nil,
      local: [BranchRef(shortName: "main", isRemote: false, upstream: nil)],
      remote: []
    )
    #expect(inventory.current == nil)
  }

  @Test
  func localAndRemoteTrackingTargetsAreDistinct() {
    let local = BranchSwitchTarget.local(name: "main")
    let remote = BranchSwitchTarget.remoteTracking(shortName: "origin/main")
    #expect(local != remote)
  }

  @Test
  func bootstrapInventoryAllowsEmptyBranchLists() {
    let inventory = BranchInventory(current: nil, local: [], remote: [])
    #expect(inventory.local.isEmpty)
    #expect(inventory.remote.isEmpty)
  }
}
