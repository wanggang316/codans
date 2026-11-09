import Foundation
import Testing

@testable import CodansCore

struct WorkspaceCheckoutTests {
  @Test
  func checkoutExposesBranchBaseRefAndManifestMode() {
    let new = WorkspaceCheckout.newBranch(branch: "feat/x", baseRef: "origin/main")
    #expect(new.branch == "feat/x")
    #expect(new.baseRef == "origin/main")
    #expect(new.manifestMode == .newBranch)
    let existing = WorkspaceCheckout.existingBranch("main")
    #expect(existing.branch == "main")
    #expect(existing.baseRef == nil)
    #expect(existing.manifestMode == .existingBranch)
  }

  @Test
  func remoteTrackingCheckoutExposesItsRefAndMode() throws {
    let tracking = WorkspaceCheckout.remoteTrackingRef(remoteRef: "origin/feat/x", branch: "feat/x", resetLocal: true)
    #expect(tracking.branch == "feat/x")
    #expect(tracking.baseRef == "origin/feat/x")
    #expect(tracking.manifestMode == .remoteTrackingRef)
    let split = try #require(WorkspaceCheckout.splitRemoteRef("origin/feat/x"))
    #expect(split.remote == "origin")
    #expect(split.branch == "feat/x")
    #expect(WorkspaceCheckout.splitRemoteRef("main") == nil)
    #expect(WorkspaceCheckout.splitRemoteRef("/x") == nil)
    #expect(WorkspaceCheckout.splitRemoteRef("origin/") == nil)
  }
}
