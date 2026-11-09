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
}
