import CodansCore
import Foundation
import Testing

@testable import Codans

/// Runs the remote command of an ssh invocation with this Mac's `sh`, as
/// the host's login shell would, with `HOME` set to a fixture. Counts the
/// round trips.
private actor LocalHostRunner: CommandRunner {
  let home: URL
  private(set) var calls = 0

  init(home: URL) {
    self.home = home
  }

  nonisolated func run(
    executable: URL, arguments: [String], env: [String: String], cwd: URL, timeout: Duration,
    maxOutputBytes: Int
  ) async -> CommandOutcome {
    await count()
    // The last ssh argument is the command the host's login shell runs.
    return await FoundationCommandRunner().run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", arguments.last ?? ""],
      env: [
        "HOME": home.path(percentEncoded: false), "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin",
        "TMPDIR": home.deletingLastPathComponent().appending(path: "tmp").path(percentEncoded: false),
      ],
      cwd: home, timeout: timeout, maxOutputBytes: maxOutputBytes)
  }

  private func count() { calls += 1 }
}

struct RemoteSkillReaderTests {
  private static let host = RemoteHost(alias: "devbox", username: "alice")
  private let root: URL
  private let home: URL
  private let repo: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "remote-skills-\(UUID().uuidString)", directoryHint: .isDirectory)
    home = root.appending(path: "home", directoryHint: .isDirectory)
    repo = root.appending(path: "srv/my app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  private func skill(_ name: String, in directory: URL, folder: String? = nil) throws {
    try write(
      "---\nname: \(name)\ndescription: |\n  \(name) skill.\n  Second line.\n---\nBody\n",
      to: directory.appending(path: "\(folder ?? name)/SKILL.md"))
  }

  /// A Claude Code home with a user skill, an enabled and a disabled
  /// plugin, and a project skill in the repository.
  private func claudeFixture() throws {
    let config = home.appending(path: ".claude", directoryHint: .isDirectory)
    try skill("mine", in: config.appending(path: "skills"), folder: "my skill")
    let docs = config.appending(path: "plugins/cache/market/docs/1.0.0")
    let off = config.appending(path: "plugins/cache/market/off/1.0.0")
    try skill("pdf", in: docs.appending(path: "skills"))
    try skill("hidden", in: off.appending(path: "skills"))
    try write(
      """
      {"plugins": {
        "docs@market": [{"installPath": "\(docs.path(percentEncoded: false))"}],
        "off@market": [{"installPath": "\(off.path(percentEncoded: false))"}]}}
      """,
      to: config.appending(path: "plugins/installed_plugins.json"))
    try write(#"{"enabledPlugins": {"docs@market": true}}"#, to: config.appending(path: "settings.json"))
    try skill("team", in: repo.appending(path: ".claude/skills"))
  }

  private func reader(_ runner: any CommandRunner) -> RemoteSkillReader {
    RemoteSkillReader(host: Self.host, runner: runner)
  }

  @Test
  func readsUserProjectAndEnabledPluginSkillsFromTheHost() async throws {
    try claudeFixture()
    let runner = LocalHostRunner(home: home)
    let entries = try await reader(runner).load(
      profile: AgentProfile(kind: .claudeCode), projectStart: repo.path(percentEncoded: false),
      newWorktree: nil, stateDirectory: root.appending(path: "state"))

    #expect(entries.map(\.name) == ["docs:pdf", "mine", "team"])
    #expect(entries.map(\.source) == [.plugin, .user, .project])
    #expect(entries.first { $0.name == "mine" }?.details == "mine skill.\nSecond line.")
    // `HOME`, then config files and the repository walk, the plugin, its skills.
    #expect(await runner.calls == 4)
  }

  @Test
  func theConfigRootVariableMovesUserSkills() async throws {
    try claudeFixture()
    let moved = root.appending(path: "claude-config", directoryHint: .isDirectory)
    try skill("relocated", in: moved.appending(path: "skills"))
    var profile = AgentProfile(kind: .claudeCode)
    profile.envVars = ["CLAUDE_CONFIG_DIR": moved.path(percentEncoded: false)]

    let entries = try await reader(LocalHostRunner(home: home)).load(
      profile: profile, projectStart: repo.path(percentEncoded: false), newWorktree: nil,
      stateDirectory: root.appending(path: "state"))

    #expect(entries.map(\.name) == ["relocated", "team"])
  }

  private func git(_ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", repo.path(percentEncoded: false)] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
  }

  /// The tmp directory of the fixture host, where views are made.
  private var hostTemp: URL { root.appending(path: "tmp", directoryHint: .isDirectory) }

  @Test
  func aNewWorktreeListsTheProjectSkillsOfItsRef() async throws {
    try claudeFixture()
    try FileManager.default.removeItem(at: repo.appending(path: ".git"))
    try FileManager.default.createDirectory(at: hostTemp, withIntermediateDirectories: true)
    try git("init", "-q", "-b", "main")
    try skill("shared", in: repo.appending(path: "tools"))
    try FileManager.default.createSymbolicLink(
      atPath: repo.appending(path: ".claude/skills/linked").path(percentEncoded: false),
      withDestinationPath: "../../tools/shared")
    try git("add", ".")
    try git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base")
    // Not in the ref: the new worktree does not get it.
    try skill("wip", in: repo.appending(path: ".claude/skills"))

    let runner = LocalHostRunner(home: home)
    let entries = try await reader(runner).load(
      profile: AgentProfile(kind: .claudeCode), projectStart: repo.path(percentEncoded: false),
      newWorktree: NewWorktreeSource(ref: "main", copyIgnored: true, copyUntracked: true),
      stateDirectory: root.appending(path: "state"))

    #expect(entries.map(\.name) == ["docs:pdf", "mine", "shared", "team"])
    let team = entries.first { $0.name == "team" }?.url.path(percentEncoded: false)
    #expect(team?.contains("codans-new-worktree.") == true)
    // The view is gone after the load.
    #expect(try FileManager.default.contentsOfDirectory(atPath: hostTemp.path(percentEncoded: false)).isEmpty)
  }

  @Test
  func aNewWorktreeWithAnUnknownRefListsUserSkillsOnly() async throws {
    try claudeFixture()
    try FileManager.default.createDirectory(at: hostTemp, withIntermediateDirectories: true)
    let entries = try await reader(LocalHostRunner(home: home)).load(
      profile: AgentProfile(kind: .claudeCode), projectStart: repo.path(percentEncoded: false),
      newWorktree: NewWorktreeSource(ref: "no-such-ref", copyIgnored: false, copyUntracked: false),
      stateDirectory: root.appending(path: "state"))

    #expect(entries.map(\.name) == ["mine"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: hostTemp.path(percentEncoded: false)).isEmpty)
  }

  @Test
  func aDanglingTargetStaysInsideTheView() {
    #expect(RemoteNewWorktreeFiles.danglingTarget(link: ".claude/skills/a", target: "../../tools/a") == "tools/a")
    #expect(RemoteNewWorktreeFiles.danglingTarget(link: ".claude/skills/a", target: "../../../outside") == nil)
    #expect(RemoteNewWorktreeFiles.danglingTarget(link: ".claude/skills/a", target: "/abs/a") == nil)
  }

  @Test
  func theViewIsRemovedOnlyByItsName() async throws {
    let runner = RecordingCommandRunner()
    await RemoteNewWorktreeFiles(reader: reader(runner)).removeView("/tmp/codans-new-worktree.abc")
    let call = try #require(await runner.calls.first)
    #expect(call.arguments.last?.contains("codans-new-worktree.*) rm -rf") == true)
  }

  @Test
  func aConnectionFailureGivesTheReason() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(
        code: 255, stdout: Data(),
        stderr: Data("ssh: connect to host devbox port 22: Connection refused\n".utf8), stdoutOverflow: false)
    ])
    await #expect(
      throws: RemoteSkillReadError(
        reason: "Could not connect to alice@devbox: ssh: connect to host devbox port 22: Connection refused")
    ) {
      try await reader(runner).load(
        profile: AgentProfile(kind: .claudeCode), projectStart: "/srv/app", newWorktree: nil)
    }
  }

  @Test
  func aTimeoutGivesTheReason() async {
    let runner = RecordingCommandRunner(outcomes: [.timedOut])
    await #expect(throws: RemoteSkillReadError(reason: "alice@devbox did not answer in time")) {
      try await reader(runner).load(
        profile: AgentProfile(kind: .claudeCode), projectStart: "/srv/app", newWorktree: nil)
    }
  }

  @Test
  func eachCallRunsTheScriptOverTheSharedConnection() async throws {
    let reply = "===CODANS-SKILL-FILES===\nh 0 9\n/home/bob\nk 0 5\nLinux\n"
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data(reply.utf8), stderr: Data(), stdoutOverflow: false)
    ])
    _ = try? await reader(runner).load(
      profile: AgentProfile(kind: .claudeCode), projectStart: "/srv/app", newWorktree: nil)

    let call = try #require(await runner.calls.first)
    #expect(call.timeout == RemoteSkillReader.timeout)
    #expect(call.arguments.contains("BatchMode=yes"))
    #expect(call.arguments.last?.contains("===CODANS-SKILL-FILES===") == true)
  }

  @Test
  func repliesSkipBannersAndKeepEveryByte() throws {
    let content = "line one\nline two\n"
    let reply = Data(
      ("Welcome!\n===CODANS-SKILL-FILES===\nh 0 9\n/home/bob\nk 0 5\nLinux\n"
        + "f 0 \(content.utf8.count)\n\(content)\nd 1 0\n\nc 1 7\nmy\nnote\ns 1 3\n---\nm 2 0\n\n").utf8)
    let snapshot = SkillFileSnapshot()
    let system = RemoteSkillReader.apply(
      reply, requests: [.file("/a"), .directory("/d"), .realPath("/r")], to: snapshot)

    #expect(system == RemoteSkillReader.System(home: "/home/bob", kernel: "Linux"))
    #expect(snapshot.contents(atPath: "/a") == Data(content.utf8))
    #expect(snapshot.contentsOfDirectory(atPath: "/d") == ["my\nnote"])
    #expect(snapshot.contents(atPath: "/d/my\nnote/SKILL.md") == Data("---".utf8))
    #expect(snapshot.realPath("/r") == nil)
    #expect(snapshot.takeMisses().isEmpty)
  }

  @Test
  func aShortOrIncompleteReplyIsRejected() {
    let header = "===CODANS-SKILL-FILES===\nh 0 9\n/home/bob\n"
    let snapshot = SkillFileSnapshot()
    // Cut inside a record.
    #expect(RemoteSkillReader.apply(Data((header + "f 0 10\nabc").utf8), requests: [.file("/a")], to: snapshot) == nil)
    // A request without an answer.
    #expect(RemoteSkillReader.apply(Data(header.utf8), requests: [.file("/a")], to: snapshot) == nil)
    // No marker.
    #expect(RemoteSkillReader.apply(Data("h 0 9\n/home/bob\n".utf8), requests: [], to: snapshot) == nil)
  }

  @Test(arguments: ["f 0 \(Int.max)\nabc\n", "f 0 \(Int.max - 1)\n\n", "f 0 -1\n\n", "f 0 99999999999999999999\n\n"])
  func aFrameLengthBeyondTheReplyIsRejected(_ frame: String) {
    let reply = Data(("===CODANS-SKILL-FILES===\nh 0 9\n/home/bob\n" + frame).utf8)
    #expect(RemoteSkillReader.records(in: reply) == nil)
  }
}
