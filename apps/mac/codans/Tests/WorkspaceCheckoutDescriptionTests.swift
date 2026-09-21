import Testing

@testable import Codans

/// The checkout line's value: what each kind of checkout says in a sentence
/// and shows as its badge, branch, and related ref.
struct WorkspaceCheckoutDescriptionTests {
  @Test
  func newBranchNamesItsBase() {
    let named = WorkspaceCheckoutDescription.newBranch(branch: "feat/y", base: "origin/release")
    #expect(named.summary == "New branch feat/y from origin/release")
    #expect(named.badge?.title == "New")
    #expect(named.branch == "feat/y")
    #expect(named.relation?.word == "from")
    #expect(named.relation?.ref == "origin/release")

    let unnamed = WorkspaceCheckoutDescription.newBranch(branch: nil, base: "the default branch")
    #expect(unnamed.summary == "New branch from the default branch, named after the title")
    #expect(unnamed.branch == nil)
    #expect(unnamed.branchPlaceholder == "Named after the title")
  }

  @Test
  func existingBranchStandsAlone() {
    let chosen = WorkspaceCheckoutDescription.existingBranch("wip")
    #expect(chosen.summary == "Branch wip")
    #expect(chosen.badge?.title == "Existing")
    #expect(chosen.relation?.word == nil)

    let unchosen = WorkspaceCheckoutDescription.existingBranch(nil)
    #expect(unchosen.summary == "Existing branch")
    #expect(unchosen.branchPlaceholder == "Choose a branch")
  }

  @Test
  func trackingRemoteTellsWhatHappensToTheLocalBranch() {
    let fresh = WorkspaceCheckoutDescription.trackingRemote(
      branch: "release", remoteRef: "origin/release", local: .none)
    #expect(fresh.summary == "Branch release, tracking origin/release")
    #expect(fresh.badge?.title == "Remote")
    #expect(fresh.relation?.word == "tracking")
    #expect(fresh.note == nil)

    let kept = WorkspaceCheckoutDescription.trackingRemote(branch: "feat/x", remoteRef: "origin/feat/x", local: .kept)
    #expect(kept.summary == "Local branch feat/x, tracking origin/feat/x")
    #expect(kept.badge?.title == "Remote")
    #expect(kept.note == "local branch kept")

    let reset = WorkspaceCheckoutDescription.trackingRemote(branch: "feat/x", remoteRef: "origin/feat/x", local: .reset)
    #expect(reset.summary == "Branch feat/x, reset to origin/feat/x")
    #expect(reset.badge?.title == "Reset")
    #expect(reset.relation?.word == "reset to")
  }

  @Test
  func checkedOutShowsOnlyTheBranchUnlessDetached() {
    let onBranch = WorkspaceCheckoutDescription.checkedOut(branch: "w-test02")
    #expect(onBranch.summary == "Branch w-test02")
    #expect(onBranch.badge?.title == nil)
    #expect(onBranch.relation?.word == nil)

    let detached = WorkspaceCheckoutDescription.checkedOut(branch: nil)
    #expect(detached.summary == "Detached")
    #expect(detached.badge?.title == "Detached")
    #expect(detached.branchPlaceholder == "No branch")
  }
}
