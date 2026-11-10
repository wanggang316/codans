import Foundation
import Testing

@testable import CodansCore

struct SkillScannerTests {
  private let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "skill-scanner-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  private func write(_ folder: String, in directory: String = "skills", _ text: String) throws {
    let url = root.appending(path: "\(directory)/\(folder)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try text.write(to: url.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
  }

  private func directory(
    _ name: String = "skills", source: AgentSkillSource = .user
  ) -> SkillDirectory {
    SkillDirectory(url: root.appending(path: name, directoryHint: .isDirectory), source: source)
  }

  @Test
  func readsNameAndTheFirstDescriptionLine() async throws {
    try write(
      "review",
      """
      ---
      name: code-review
      description: |
        Review a change.
        Second line.
      ---
      Body
      """)
    try write("tdd", "---\nname: tdd\ndescription: \"Write tests first.\"\n---\n")
    let entries = await SkillScanner.scan([directory()])
    #expect(entries.map(\.name) == ["code-review", "tdd"])
    #expect(entries.map(\.summary) == ["Review a change.", "Write tests first."])
    #expect(entries.map(\.details) == ["Review a change.\nSecond line.", "Write tests first."])
    #expect(entries.allSatisfy { $0.source == .user })
  }

  @Test
  func brokenFrontmatterIsListedByFolderNameWithoutDescription() async throws {
    try write("unclosed", "---\nname: other\ndescription: never closed\n")
    try write("bad-yaml", "---\nname: [unclosed\ndescription: x\n---\n")
    try write("no-frontmatter", "# Just a body\n")
    let entries = await SkillScanner.scan([directory()])
    #expect(entries.map(\.name) == ["bad-yaml", "no-frontmatter", "unclosed"])
    #expect(entries.allSatisfy { $0.summary == nil && $0.details == nil })
  }

  @Test
  func missingNameFallsBackToTheFolderName() async throws {
    try write("helper", "---\ndescription: Helps.\n---\n")
    let entries = await SkillScanner.scan([directory()])
    #expect(entries == [AgentSkillEntry(name: "helper", summary: "Helps.", details: "Helps.", source: .user, url: entries[0].url)])
  }

  @Test
  func foldersWithoutSkillFileAndMissingDirectoriesAreSkipped() async throws {
    try FileManager.default.createDirectory(
      at: root.appending(path: "skills/empty"), withIntermediateDirectories: true)
    try write("real", "---\nname: real\n---\n")
    let entries = await SkillScanner.scan([directory(), directory("missing")])
    #expect(entries.map(\.name) == ["real"])
  }

  @Test
  func symlinkedSkillFolderIsRead() async throws {
    try write("target", in: "source", "---\nname: linked\n---\n")
    try FileManager.default.createDirectory(
      at: root.appending(path: "skills"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "skills/linked"),
      withDestinationURL: root.appending(path: "source/target"))
    let entries = await SkillScanner.scan([directory()])
    #expect(entries.map(\.name) == ["linked"])
  }

  @Test
  func firstDirectoryWinsForOneName() async throws {
    try write("dup", in: "a", "---\nname: dup\ndescription: from a\n---\n")
    try write("dup", in: "b", "---\nname: dup\ndescription: from b\n---\n")
    let entries = await SkillScanner.scan([directory("a"), directory("b")])
    #expect(entries.map(\.summary) == ["from a"])
  }

  @Test
  func precedenceKeepsOneEntryForANameInProjectAndUserFolders() async throws {
    try write("dup", in: "project", "---\nname: dup\ndescription: from project\n---\n")
    try write("dup", in: "user", "---\nname: dup\ndescription: from user\n---\n")
    try write("only", in: "project", "---\nname: only\n---\n")
    let directories = [directory("project", source: .project), directory("user", source: .user)]

    let userFirst = await SkillScanner.scan(directories, precedence: [.user, .project])
    #expect(userFirst.map(\.name) == ["dup", "only"])
    #expect(userFirst.map(\.source) == [.user, .project])
    #expect(userFirst.first?.summary == "from user")

    let projectFirst = await SkillScanner.scan(directories, precedence: [.project, .user])
    #expect(projectFirst.map(\.source) == [.project, .project])
    #expect(projectFirst.first?.summary == "from project")
  }

  @Test
  func claudeCodePrecedenceKeepsTheUserSkill() async throws {
    try write("dup", in: "project", "---\nname: dup\n---\n")
    try write("dup", in: "user", "---\nname: dup\n---\n")
    let entries = await SkillScanner.scan(
      [directory("project", source: .project), directory("user", source: .user)],
      precedence: SkillLocation.claudeCode.precedence)
    #expect(entries.map(\.source) == [.user])
  }

  @Test
  func recordsWhetherModelInvocationIsDisabled() async throws {
    try write("manual", "---\nname: manual\ndisable-model-invocation: true\n---\n")
    try write("allowed", "---\nname: allowed\ndisable-model-invocation: false\n---\n")
    try write("absent", "---\nname: absent\n---\n")
    try write("broken", "---\nname: [broken\ndisable-model-invocation: true\n---\n")
    let entries = await SkillScanner.scan([directory()])
    let flags = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.disablesModelInvocation) })
    #expect(flags == ["manual": true, "allowed": false, "absent": false, "broken": false])
  }
}
