import Foundation
import Testing

@testable import CodansCore

/// Skill completion against another host: the resolver and the scanner run
/// on a `SkillFileSnapshot` whose reads are answered in batches.
struct SkillFileSnapshotTests {
  private let root: URL
  private let home: URL
  private let stateRoot: URL
  private let repo: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "skill-snapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
    home = root.appending(path: "home", directoryHint: .isDirectory)
    stateRoot = root.appending(path: "state", directoryHint: .isDirectory)
    repo = root.appending(path: "repo", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  private func skill(_ name: String, in directory: URL) throws {
    try write(
      "---\nname: \(name)\ndescription: \(name) skill.\n---\n",
      to: directory.appending(path: "\(name)/SKILL.md"))
  }

  /// Answers `requests` from this Mac, as the remote reader answers them
  /// from the host.
  private static func answer(_ requests: [SkillFileSnapshot.Request], into snapshot: SkillFileSnapshot) {
    let local = LocalSkillFileSystem()
    for request in requests {
      switch request {
      case .file(let path):
        if let data = local.contents(atPath: path) {
          snapshot.setFile(path, .data(data))
        } else {
          snapshot.setFile(path, local.fileExists(atPath: path) ? .unreadable : .missing)
        }
      case .directory(let path):
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
          let names = local.contentsOfDirectory(atPath: path)
        else {
          snapshot.setDirectory(path, nil)
          continue
        }
        snapshot.setDirectory(
          path,
          names.map { name in
            .init(name: name, skill: local.contents(atPath: path + "/" + name + "/SKILL.md"))
          })
      case .realPath(let path):
        snapshot.setRealPath(path, local.realPath(path))
      }
    }
  }

  private func scan(_ profile: AgentProfile, start: URL, fileSystem: any SkillFileSystem) -> [AgentSkillEntry] {
    SkillScanner.scanSync(
      SkillLocationResolver.directories(
        for: profile, projectStart: start, userHome: home, stateDirectory: stateRoot,
        managedSettings: root.appending(path: "managed.json"), fileSystem: fileSystem),
      precedence: profile.descriptor.skillLocation.precedence, fileSystem: fileSystem)
  }

  private func settled(_ profile: AgentProfile, start: URL) async -> (entries: [AgentSkillEntry]?, rounds: Int) {
    let snapshot = SkillFileSnapshot()
    var rounds = 0
    let entries = await snapshot.settle(maxRounds: 10) {
      scan(profile, start: start, fileSystem: snapshot)
    } fetch: { requests in
      rounds += 1
      Self.answer(requests, into: snapshot)
    }
    return (entries, rounds)
  }

  @Test
  func claudeCodeSettlesToTheLocalResult() async throws {
    let start = repo.appending(path: "packages/app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
    try skill("near", in: start.appending(path: ".claude/skills"))
    try skill("top", in: repo.appending(path: ".claude/skills"))
    let config = home.appending(path: ".claude", directoryHint: .isDirectory)
    try skill("mine", in: config.appending(path: "skills"))
    let docs = config.appending(path: "plugins/cache/market/docs/1.0.0")
    try skill("pdf", in: docs.appending(path: "skills"))
    try write(
      #"{"plugins": {"docs@market": [{"installPath": "\#(docs.path(percentEncoded: false))"}]}}"#,
      to: config.appending(path: "plugins/installed_plugins.json"))
    try write(#"{"enabledPlugins": {"docs@market": true}}"#, to: config.appending(path: "settings.json"))

    let profile = AgentProfile(kind: .claudeCode)
    let local = scan(profile, start: start, fileSystem: LocalSkillFileSystem())
    let (remote, rounds) = await settled(profile, start: start)

    #expect(local.map(\.name) == ["docs:pdf", "mine", "near", "top"])
    #expect(remote == local)
    // Config files and the repository walk, then the plugin, then its skills.
    #expect(rounds == 3)
  }

  @Test
  func piTrustSettlesToTheLocalResult() async throws {
    try FileManager.default.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
    try skill("project-skill", in: repo.appending(path: ".pi/skills"))
    let agent = home.appending(path: ".pi/agent", directoryHint: .isDirectory)
    try skill("user-skill", in: agent.appending(path: "skills"))
    let canonical = try #require(LocalSkillFileSystem().realPath(repo.path(percentEncoded: false)))
    try write(#"{"\#(canonical)": true}"#, to: agent.appending(path: "trust.json"))

    let profile = AgentProfile(kind: .pi)
    let local = scan(profile, start: repo, fileSystem: LocalSkillFileSystem())
    let (remote, _) = await settled(profile, start: repo)

    #expect(local.map(\.name) == ["project-skill", "user-skill"])
    #expect(remote == local)
  }

  @Test
  func aMissingGitEntryAsksForEveryParent() {
    let snapshot = SkillFileSnapshot()
    #expect(!snapshot.fileExists(atPath: "/srv/app/sub/.git"))
    #expect(
      snapshot.takeMisses() == [
        .file("/srv/app/sub/.git"), .file("/srv/app/.git"), .file("/srv/.git"), .file("/.git"),
      ])
  }

  @Test
  func aDirectoryAnswerCarriesEachChildsSkillFile() {
    let snapshot = SkillFileSnapshot()
    snapshot.setDirectory(
      "/home/a/.claude/skills/",
      [.init(name: "one", skill: Data("---\nname: one\n---\n".utf8)), .init(name: "notes.txt")])
    #expect(snapshot.contentsOfDirectory(atPath: "/home/a/.claude/skills") == ["one", "notes.txt"])
    #expect(snapshot.contents(atPath: "/home/a/.claude/skills/one/SKILL.md") != nil)
    #expect(!snapshot.fileExists(atPath: "/home/a/.claude/skills/notes.txt/SKILL.md"))
    #expect(snapshot.fileExists(atPath: "/home/a/.claude/skills"))
    #expect(snapshot.takeMisses().isEmpty)
  }

  @Test
  func missesAreAskedOnce() {
    let snapshot = SkillFileSnapshot()
    _ = snapshot.contents(atPath: "/a/settings.json")
    _ = snapshot.fileExists(atPath: "/a/settings.json")
    _ = snapshot.contentsOfDirectory(atPath: "/a/skills/")
    _ = snapshot.contentsOfDirectory(atPath: "/a/skills")
    _ = snapshot.realPath("/a")
    #expect(snapshot.takeMisses() == [.file("/a/settings.json"), .directory("/a/skills"), .realPath("/a")])
    #expect(snapshot.takeMisses().isEmpty)
  }

  @Test
  func settleGivesUpAfterTheRoundLimit() async {
    let snapshot = SkillFileSnapshot()
    var counter = 0
    var fetches = 0
    let result: Int? = await snapshot.settle(maxRounds: 2) {
      counter += 1
      return snapshot.contents(atPath: "/file-\(counter)") == nil ? counter : 0
    } fetch: { requests in
      fetches += 1
      for case .file(let path) in requests { snapshot.setFile(path, .missing) }
    }
    #expect(result == nil)
    #expect(fetches == 2)
  }
}
