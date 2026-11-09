import Foundation
import Testing

@testable import Codans
@testable import CodansCore

/// Skill completion for a New Worktree target reads the main checkout, less
/// the files the copy options leave out. A real repository decides which
/// files are tracked, ignored, or untracked.
struct NewWorktreeFilesTests {
  private let repo: URL
  private let home: URL
  private let stateRoot: URL
  private let managed: URL

  init() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "new-worktree-files-\(UUID().uuidString)", directoryHint: .isDirectory)
    repo = root.appending(path: "repo", directoryHint: .isDirectory)
    home = root.appending(path: "home", directoryHint: .isDirectory)
    stateRoot = root.appending(path: "state", directoryHint: .isDirectory)
    managed = root.appending(path: "managed-settings.json")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
  }

  private func git(_ args: [String]) async throws {
    let outcome = await FoundationCommandRunner().run(
      executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: args,
      env: GitProcessEnv.build(), cwd: repo, timeout: .seconds(10), maxOutputBytes: 1024 * 1024)
    guard case .exited(0, _, _, false) = outcome else {
      throw GitError.unparsable(context: "Fixture command failed: \(args): \(outcome)")
    }
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  private func skill(_ name: String, in directory: URL) throws {
    try write("---\nname: \(name)\n---\n", to: directory.appending(path: "\(name)/SKILL.md"))
  }

  /// Plugins `tracked`, `ignored`, and `untracked`, installed and off in the
  /// user settings. Each is enabled only by the project settings file of
  /// the same kind.
  private func fixture(local: String) async throws {
    let configRoot = home.appending(path: ".claude")
    var installs: [String] = []
    for name in ["tracked", "ignored", "untracked"] {
      let path = configRoot.appending(path: "plugins/cache/market/\(name)/1.0.0")
      try skill("run", in: path.appending(path: "skills"))
      installs.append(#""\#(name)@market": [{"installPath": "\#(path.path(percentEncoded: false))"}]"#)
    }
    try write(
      #"{"plugins": {\#(installs.joined(separator: ","))}}"#,
      to: configRoot.appending(path: "plugins/installed_plugins.json"))
    try write(#"{"enabledPlugins": {}}"#, to: configRoot.appending(path: "settings.json"))

    try await git(["init", "-b", "main"])
    // The user's global excludes file would ignore files this test means
    // to leave untracked.
    try await git(["config", "core.excludesFile", "/dev/null"])
    try write(".claude/settings.local.json\n.claude/skills/scratch/\n", to: repo.appending(path: ".gitignore"))
    try write(
      #"{"enabledPlugins": {"tracked@market": true}}"#, to: repo.appending(path: ".claude/settings.json"))
    try skill("shared", in: repo.appending(path: ".claude/skills"))
    try await git(["add", "."])
    try await git(["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-qm", "init"])
    // Not committed: `.claude/settings.local.json` is ignored here, and the
    // `draft` skill is untracked.
    try write(local, to: repo.appending(path: ".claude/settings.local.json"))
    try skill("scratch", in: repo.appending(path: ".claude/skills"))
    try skill("draft", in: repo.appending(path: ".claude/skills"))
  }

  private func names(copyIgnored: Bool, copyUntracked: Bool) async -> [String] {
    let exclusion = await NewWorktreeFiles.exclusion(
      repoRoot: repo, copyIgnored: copyIgnored, copyUntracked: copyUntracked)
    let profile = AgentProfile(kind: .claudeCode)
    let directories =
      SkillLocationResolver.projectDirectories(for: profile, startDirectory: repo)
      + SkillLocationResolver.pluginDirectories(
        for: profile, projectStart: repo, userHome: home, stateDirectory: stateRoot,
        managedSettings: managed, excluding: exclusion)
    return SkillScanner.scanSync(directories, excluding: exclusion).map(\.name)
  }

  @Test
  func ignoredLocalSettingsCountOnlyWhenIgnoredFilesAreCopied() async throws {
    try await fixture(local: #"{"enabledPlugins": {"ignored@market": true}}"#)
    #expect(await names(copyIgnored: false, copyUntracked: false) == ["shared", "tracked:run"])
    #expect(await names(copyIgnored: false, copyUntracked: true) == ["draft", "shared", "tracked:run"])
    #expect(
      await names(copyIgnored: true, copyUntracked: false) == [
        "ignored:run", "scratch", "shared", "tracked:run",
      ])
    #expect(
      await names(copyIgnored: true, copyUntracked: true) == [
        "draft", "ignored:run", "scratch", "shared", "tracked:run",
      ])
  }

  @Test
  func untrackedLocalSettingsCountOnlyWhenUntrackedFilesAreCopied() async throws {
    try await fixture(local: #"{"enabledPlugins": {"untracked@market": true}}"#)
    // Not ignored: the file is untracked.
    try write(".claude/skills/scratch/\n", to: repo.appending(path: ".gitignore"))
    try await git(["add", ".gitignore"])
    try await git(["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-qm", "unignore"])
    #expect(await names(copyIgnored: true, copyUntracked: false) == ["scratch", "shared", "tracked:run"])
    #expect(
      await names(copyIgnored: false, copyUntracked: true) == [
        "draft", "shared", "tracked:run", "untracked:run",
      ])
  }

  /// `.claude/` holds an ignored and untracked files, no tracked one. Git
  /// lists such a directory as one `dir/` entry for the untracked files, but
  /// `wt` still copies its ignored files.
  @Test
  func ignoredFilesInADirectoryWithUntrackedFilesCountWhenCopied() async throws {
    try await fixture(local: #"{"enabledPlugins": {"ignored@market": true}}"#)
    try await git(["rm", "-rq", "--cached", ".claude"])
    try await git(["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-qm", "untrack"])
    #expect(await names(copyIgnored: true, copyUntracked: false) == ["ignored:run", "scratch"])
    #expect(await names(copyIgnored: false, copyUntracked: false) == [])
  }

  /// A tracked settings file is in every new worktree. Here the local file
  /// turns the tracked plugin off, which counts only when it is copied.
  @Test
  func trackedSettingsAreReadWhateverTheCopyOptions() async throws {
    try await fixture(local: #"{"enabledPlugins": {"tracked@market": false}}"#)
    #expect(await names(copyIgnored: false, copyUntracked: false).contains("tracked:run"))
    #expect(await names(copyIgnored: false, copyUntracked: true).contains("tracked:run"))
    #expect(!(await names(copyIgnored: true, copyUntracked: false)).contains("tracked:run"))
  }

  @Test
  func bothCopyOptionsOnExcludeNothing() async {
    #expect(await NewWorktreeFiles.exclusion(repoRoot: repo, copyIgnored: true, copyUntracked: true) == nil)
  }

  @Test
  func failedListingExcludesEveryProjectFile() async {
    // Not a repository: git fails.
    let exclusion = await NewWorktreeFiles.exclusion(
      repoRoot: repo, copyIgnored: false, copyUntracked: true)
    #expect(exclusion?.paths == nil)
    #expect(exclusion?.excludes(repo.appending(path: ".claude/settings.json")) == true)
  }
}
