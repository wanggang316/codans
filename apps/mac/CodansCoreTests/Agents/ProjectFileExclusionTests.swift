import Foundation
import Testing

@testable import CodansCore

struct ProjectFileExclusionTests {
  private let root = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)

  private func excludes(_ path: String, paths: Set<String>? = [".claude/settings.local.json", "scratch/"])
    -> Bool
  {
    ProjectFileExclusion(root: root, paths: paths).excludes(URL(fileURLWithPath: path))
  }

  @Test
  func listedFileAndFilesInAListedDirectoryAreExcluded() {
    #expect(excludes("/tmp/repo/.claude/settings.local.json"))
    #expect(excludes("/tmp/repo/scratch/a/SKILL.md"))
  }

  /// Git lists a symlink as a file, without `/`, also when it points to a
  /// directory. The files reached through it go with it.
  @Test
  func filesThroughAListedSymlinkAreExcluded() {
    #expect(excludes("/tmp/repo/.claude/skills/linked/SKILL.md", paths: [".claude/skills/linked"]))
    #expect(!excludes("/tmp/repo/.claude/skills/linked2/SKILL.md", paths: [".claude/skills/linked"]))
  }

  @Test
  func otherFilesAreKept() {
    #expect(!excludes("/tmp/repo/.claude/settings.json"))
    #expect(!excludes("/tmp/repo/scratchpad/SKILL.md"))
    #expect(!excludes("/tmp/repo/.claude/settings.local.json.bak"))
  }

  @Test
  func filesOutsideTheRootAreKept() {
    #expect(!excludes("/tmp/other/.claude/settings.local.json"))
    #expect(!excludes("/tmp/repository/x", paths: nil))
    #expect(!excludes("/Users/me/.claude/settings.json", paths: nil))
  }

  @Test
  func unknownListExcludesEveryFileUnderTheRoot() {
    #expect(excludes("/tmp/repo/.claude/settings.json", paths: nil))
  }

  // MARK: - Symlinks the new worktree has

  /// A real directory under the temporary directory. Its path goes through
  /// the `/var` symlink, as a project path can.
  private func makeRepo() throws -> URL {
    let repo = FileManager.default.temporaryDirectory
      .appending(path: "exclusion-\(UUID().uuidString)/repo", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    return repo
  }

  private func link(_ path: String, to destination: String, in repo: URL) throws {
    let url = repo.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: url.path(percentEncoded: false), withDestinationPath: destination)
  }

  private func file(_ path: String, in repo: URL) throws {
    let url = repo.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: url)
  }

  /// The new worktree has the symlink but not its listed target, so the
  /// files through it are gone.
  @Test
  func filesThroughASymlinkToAListedTargetAreExcluded() throws {
    let repo = try makeRepo()
    try file("vendor/skill/SKILL.md", in: repo)
    try link(".claude/skills/skill", to: "../../vendor/skill", in: repo)
    try link(".claude/skills/absolute", to: repo.appending(path: "vendor/skill").path(percentEncoded: false), in: repo)
    try link(".agents", to: "vendor", in: repo)
    let exclusion = ProjectFileExclusion(root: repo, paths: ["vendor/"])
    #expect(exclusion.excludes(repo.appending(path: ".claude/skills/skill/SKILL.md")))
    #expect(exclusion.excludes(repo.appending(path: ".claude/skills/absolute/SKILL.md")))
    #expect(exclusion.excludes(repo.appending(path: ".agents/skill/SKILL.md")))
    #expect(!ProjectFileExclusion(root: repo, paths: []).excludes(repo.appending(path: ".claude/skills/skill/SKILL.md")))
  }

  /// A symlink on the way that the new worktree does not have makes the
  /// whole path dangle, also when the final target is kept.
  @Test
  func filesThroughAListedSymlinkOnTheWayAreExcluded() throws {
    let repo = try makeRepo()
    try file("skills/kept/SKILL.md", in: repo)
    try link("local", to: "skills", in: repo)
    try link(".claude/skills", to: "../local", in: repo)
    let exclusion = ProjectFileExclusion(root: repo, paths: ["local"])
    #expect(exclusion.excludes(repo.appending(path: ".claude/skills/kept/SKILL.md")))
    #expect(!exclusion.excludes(repo.appending(path: "skills/kept/SKILL.md")))
  }

  /// A relative symlink that leaves the repository points somewhere else
  /// from the new worktree, which is in another directory. An absolute one
  /// points to the same place.
  @Test
  func relativeSymlinkOutOfTheRootIsExcludedAndAnAbsoluteOneIsKept() throws {
    let repo = try makeRepo()
    let outside = repo.deletingLastPathComponent().appending(path: "shared", directoryHint: .isDirectory)
    try file("skill/SKILL.md", in: outside)
    try link(".claude/skills/relative", to: "../../../shared/skill", in: repo)
    try link(
      ".claude/skills/absolute", to: outside.appending(path: "skill").path(percentEncoded: false), in: repo)
    let exclusion = ProjectFileExclusion(root: repo, paths: [])
    #expect(exclusion.excludes(repo.appending(path: ".claude/skills/relative/SKILL.md")))
    #expect(!exclusion.excludes(repo.appending(path: ".claude/skills/absolute/SKILL.md")))
  }

  @Test
  func symlinkLoopIsExcluded() throws {
    let repo = try makeRepo()
    try link("a", to: "b", in: repo)
    try link("b", to: "a", in: repo)
    #expect(ProjectFileExclusion(root: repo, paths: []).excludes(repo.appending(path: "a/SKILL.md")))
  }
}
