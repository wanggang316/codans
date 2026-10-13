import Foundation
import Testing

@testable import CodansCore

struct WorkflowDiscoveryTests {
  private let minimal = """
    name: Minimal
    roles:
      author: {source: current}
    steps:
      - message: author
        text: hello
    """

  private func makeTree() throws -> (root: URL, bundle: URL, user: URL, worktree: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("workflow-discovery-\(UUID().uuidString)", isDirectory: true)
    let bundle = root.appendingPathComponent("bundle", isDirectory: true)
    let user = root.appendingPathComponent("user", isDirectory: true)
    let worktree = root.appendingPathComponent("worktree", isDirectory: true)
    for directory in [bundle, user, WorkflowDiscovery.repositoryDirectory(worktreeRoot: worktree)] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return (root, bundle, user, worktree)
  }

  @Test
  func laterScopesShadowEarlierOnesAndInvalidFilesStayListed() throws {
    let tree = try makeTree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    try minimal.write(
      to: tree.bundle.appendingPathComponent("review-loop.workflow.yaml"), atomically: true, encoding: .utf8)
    try minimal.replacingOccurrences(of: "Minimal", with: "User Copy")
      .write(to: tree.user.appendingPathComponent("review-loop.workflow.yaml"), atomically: true, encoding: .utf8)
    try "name: Broken\nsteps: []\n"
      .write(
        to: WorkflowDiscovery.repositoryDirectory(worktreeRoot: tree.worktree)
          .appendingPathComponent("ci.workflow.yaml"), atomically: true, encoding: .utf8)
    try "not a workflow".write(to: tree.user.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

    let discovery = WorkflowDiscovery(bundleDirectory: tree.bundle, userDirectory: tree.user)
    let catalog = discovery.catalog(worktreeRoot: tree.worktree)
    #expect(catalog.map(\.id) == ["ci", "review-loop"])
    #expect(catalog[1].scope == .user)
    #expect(catalog[1].name == "User Copy")
    #expect(catalog[1].isValid)
    #expect(!catalog[0].isValid)
    #expect(catalog[0].definition == nil)
    #expect(!catalog[0].diagnostics.isEmpty)
    #expect(discovery.scanAll(worktreeRoot: tree.worktree).count == 3)
    #expect(discovery.catalog(worktreeRoot: nil).map(\.id) == ["review-loop"])
  }

  @Test
  func resolvesByIDThenUniqueNameAndHashesContent() throws {
    let tree = try makeTree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    let url = tree.user.appendingPathComponent("summarize.workflow.yaml")
    try minimal.write(to: url, atomically: true, encoding: .utf8)
    let discovery = WorkflowDiscovery(bundleDirectory: nil, userDirectory: tree.user)
    #expect(discovery.resolve("summarize", worktreeRoot: nil)?.id == "summarize")
    #expect(discovery.resolve("minimal", worktreeRoot: nil)?.id == "summarize")
    #expect(discovery.resolve("nope", worktreeRoot: nil) == nil)
    let entry = try #require(discovery.resolve("summarize", worktreeRoot: nil))
    #expect(entry.sha256 == WorkflowDiscovery.sha256(of: Data(minimal.utf8)))
    #expect(entry.sha256.count == 64)
    #expect(!entry.requiresTrust)
  }
}
