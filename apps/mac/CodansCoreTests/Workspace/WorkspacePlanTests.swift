import Foundation
import Testing

@testable import CodansCore

struct WorkspacePlanTests {
  private func member(_ name: String, source: String = "/src/\(UUID().uuidString)") -> WorkspacePlan.Member {
    WorkspacePlan.Member(
      name: name, sourceGitRoot: source, checkout: .newBranch(branch: "feat/x", baseRef: nil))
  }

  @Test
  func validateAcceptsAWellFormedPlan() {
    let plan = WorkspacePlan(
      title: "Checkout Flow", rootPath: "/tmp/ws", members: [member("app"), member("api")])
    #expect(plan.validate().isEmpty)
  }

  @Test
  func validateReportsEveryStructuralProblem() {
    let plan = WorkspacePlan(
      title: "  ",
      rootPath: "",
      members: [
        WorkspacePlan.Member(name: "../x", sourceGitRoot: " ", checkout: .existingBranch(" ")),
        member("dup"),
        member("dup"),
      ])
    let issues = plan.validate()
    #expect(issues.contains(.emptyTitle))
    #expect(issues.contains(.emptyRootPath))
    #expect(issues.contains(.invalidMemberName("../x")))
    #expect(issues.contains(.duplicateMemberName("dup")))
    #expect(issues.contains(.emptySource(member: "../x")))
    #expect(issues.contains(.emptyBranch(member: "../x")))
    // Three members, so no count issue.
    #expect(!issues.contains(.tooFewMembers(3)))
  }

  @Test
  func validateRequiresTwoMembersButAddFlowDoesNot() {
    let plan = WorkspacePlan(title: "T", rootPath: "/tmp/ws", members: [member("app")])
    #expect(plan.validate() == [.tooFewMembers(1)])
    #expect(WorkspacePlan.validate(members: [member("app")]).isEmpty)
  }

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
  func manifestMirrorsThePlan() {
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let plan = WorkspacePlan(
      title: "Checkout Flow",
      rootPath: "/tmp/ws",
      description: "d",
      taskLinks: ["https://example.com/1"],
      members: [
        WorkspacePlan.Member(
          name: "app", sourceGitRoot: "/src/app", role: "macOS app",
          checkout: .newBranch(branch: "feat/x", baseRef: "origin/main")),
        WorkspacePlan.Member(
          name: "api", sourceGitRoot: "/src/api", checkout: .existingBranch("main")),
      ])
    let manifest = plan.manifest(createdAt: created)
    #expect(manifest.title == "Checkout Flow")
    #expect(manifest.description == "d")
    #expect(manifest.taskLinks == ["https://example.com/1"])
    #expect(manifest.createdAt == created)
    #expect(manifest.repositories.count == 2)
    let app = manifest.repositories[0]
    #expect(app.name == "app")
    #expect(app.path == "app")
    #expect(app.role == "macOS app")
    #expect(app.sourceGitRoot == "/src/app")
    #expect(app.checkoutMode == .newBranch)
    #expect(app.branch == "feat/x")
    #expect(app.baseRef == "origin/main")
    let api = manifest.repositories[1]
    #expect(api.checkoutMode == .existingBranch)
    #expect(api.branch == "main")
    #expect(api.baseRef == nil)
    #expect(manifest.validate().isEmpty)
  }

  @Test
  func ledgerUndoesInReverseWithWorktreeBeforeBranch() {
    var ledger = WorkspaceMaterializationLedger()
    #expect(ledger.isEmpty)
    ledger.record(.createdDirectory(path: "/tmp/ws"))
    ledger.record(.createdBranch(repoRoot: "/src/app", branch: "feat/x"))
    ledger.record(.addedWorktree(repoRoot: "/src/app", path: "/tmp/ws/app"))
    #expect(
      ledger.rollbackSteps == [
        .addedWorktree(repoRoot: "/src/app", path: "/tmp/ws/app"),
        .createdBranch(repoRoot: "/src/app", branch: "feat/x"),
        .createdDirectory(path: "/tmp/ws"),
      ])
  }
}
