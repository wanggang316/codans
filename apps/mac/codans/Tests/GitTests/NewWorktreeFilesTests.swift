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

  private func commit(_ message: String, _ paths: [String]) async throws {
    try await git(["add", "--"] + paths)
    try await git(["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-qm", message])
  }

  /// The skills an agent in a new worktree from `ref` gets: the project
  /// files come from a view of that worktree.
  private func names(
    ref: String = "HEAD", copyIgnored: Bool, copyUntracked: Bool,
    profile: AgentProfile = AgentProfile(kind: .claudeCode)
  ) async -> [String] {
    guard
      let view = await NewWorktreeFiles.makeView(
        repoRoot: repo, ref: ref, copyIgnored: copyIgnored, copyUntracked: copyUntracked,
        paths: SkillLocationResolver.projectFilePaths(for: profile))
    else { return ["<no view>"] }
    defer { try? FileManager.default.removeItem(at: view) }
    let directories =
      SkillLocationResolver.projectDirectories(for: profile, startDirectory: view)
      + SkillLocationResolver.pluginDirectories(
        for: profile, projectStart: view, projectStartExists: false, userHome: home,
        stateDirectory: stateRoot, managedSettings: managed)
    return SkillScanner.scanSync(directories).map(\.name)
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

  /// An untracked symlink to a skill folder is one file to git. The new
  /// worktree gets it, and the skill through it, only with Copy untracked.
  @Test
  func skillThroughAnUntrackedSymlinkCountsOnlyWhenUntrackedFilesAreCopied() async throws {
    try await fixture(local: "{}")
    let source = home.appending(path: "skill-source", directoryHint: .isDirectory)
    try skill("linked", in: source)
    try FileManager.default.createSymbolicLink(
      at: repo.appending(path: ".claude/skills/linked"), withDestinationURL: source.appending(path: "linked"))
    #expect(!(await names(copyIgnored: true, copyUntracked: false)).contains("linked"))
    #expect(await names(copyIgnored: false, copyUntracked: true).contains("linked"))
  }

  /// A tracked symlink is in every new worktree, but its target in the
  /// repository can be ignored. Without Copy ignored the new worktree's
  /// symlink dangles, so the skill through it is not offered.
  @Test
  func skillThroughATrackedSymlinkToAnIgnoredTargetCountsOnlyWhenIgnoredFilesAreCopied() async throws {
    try await fixture(local: "{}")
    try write(
      ".claude/settings.local.json\n.claude/skills/scratch/\nvendor/\n", to: repo.appending(path: ".gitignore"))
    try skill("vendored", in: repo.appending(path: "vendor"))
    try FileManager.default.createSymbolicLink(
      atPath: repo.appending(path: ".claude/skills/vendored").path(percentEncoded: false),
      withDestinationPath: "../../vendor/vendored")
    try await git(["add", ".gitignore", ".claude/skills/vendored"])
    try await git(["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-qm", "vendored"])
    #expect(!(await names(copyIgnored: false, copyUntracked: true)).contains("vendored"))
    #expect(await names(copyIgnored: true, copyUntracked: false).contains("vendored"))
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
  func bothCopyOptionsCopyEveryFile() async throws {
    try await fixture(local: #"{"enabledPlugins": {"ignored@market": true}}"#)
    #expect(
      await names(copyIgnored: true, copyUntracked: true) == [
        "draft", "ignored:run", "scratch", "shared", "tracked:run",
      ])
  }

  /// The tracked files come from the ref the worktree is created from, not
  /// from the main checkout: a skill only on the ref is offered, a skill
  /// only in the checkout is not, and the ref's settings decide plugins.
  @Test
  func trackedFilesComeFromTheRef() async throws {
    try await fixture(local: "{}")
    try await git(["switch", "-q", "-c", "next"])
    try skill("next-only", in: repo.appending(path: ".claude/skills"))
    try write(#"{"enabledPlugins": {}}"#, to: repo.appending(path: ".claude/settings.json"))
    try await commit("next", [".claude/skills/next-only", ".claude/settings.json"])
    try await git(["switch", "-q", "main"])
    #expect(await names(ref: "main", copyIgnored: false, copyUntracked: false) == ["shared", "tracked:run"])
    #expect(await names(ref: "next", copyIgnored: false, copyUntracked: false) == ["next-only", "shared"])

    // An uncommitted change in the checkout is not in the new worktree.
    try FileManager.default.removeItem(at: repo.appending(path: ".claude/skills/shared"))
    #expect(await names(ref: "main", copyIgnored: false, copyUntracked: false) == ["shared", "tracked:run"])
  }

  /// `wt` copies without overwriting: a file the ref tracks stays the
  /// ref's, also when the main checkout has an ignored or untracked file
  /// at that path.
  @Test
  func copiedFilesDoNotReplaceTheRefsFiles() async throws {
    try await fixture(local: "{}")
    try await git(["switch", "-q", "-c", "next"])
    try write("---\nname: dup-ref\n---\n", to: repo.appending(path: ".claude/skills/dup/SKILL.md"))
    try write("---\nname: scratch-ref\n---\n", to: repo.appending(path: ".claude/skills/scratch/SKILL.md"))
    try await git(["add", "-f", "--", ".claude/skills/dup", ".claude/skills/scratch"])
    try await git(["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-qm", "next"])
    try await git(["switch", "-q", "main"])
    // The main checkout has its own files at the same paths: `dup` is
    // untracked there, `scratch` ignored.
    try write("---\nname: dup-local\n---\n", to: repo.appending(path: ".claude/skills/dup/SKILL.md"))
    try write("---\nname: scratch-local\n---\n", to: repo.appending(path: ".claude/skills/scratch/SKILL.md"))
    let names = await names(ref: "next", copyIgnored: true, copyUntracked: true)
    #expect(names.contains("dup-ref") && names.contains("scratch-ref"))
    #expect(!names.contains("dup-local") && !names.contains("scratch-local"))
  }

  /// A `--settings` file outside the repository is not one of the new
  /// worktree's files: its place relative to the new worktree is unknown.
  /// The project skills stay; the plugin skills, which it can turn on or
  /// off, go.
  @Test
  func settingsOutsideTheRepositoryKeepProjectSkills() async throws {
    try await fixture(local: "{}")
    let profile = AgentProfile(kind: .claudeCode, extraArguments: "--settings ../settings.json")
    #expect(await names(copyIgnored: false, copyUntracked: false, profile: profile) == ["shared"])
  }

  /// A tracked symlink to a tracked folder outside the skill directory is
  /// followed: the new worktree has both.
  @Test
  func skillThroughATrackedSymlinkToATrackedTargetIsOffered() async throws {
    try await fixture(local: "{}")
    try skill("vendored", in: repo.appending(path: "vendor"))
    try FileManager.default.createSymbolicLink(
      atPath: repo.appending(path: ".claude/skills/vendored").path(percentEncoded: false),
      withDestinationPath: "../../vendor/vendored")
    try await git(["add", "vendor", ".claude/skills/vendored"])
    try await git(["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-qm", "vendored"])
    #expect(await names(copyIgnored: false, copyUntracked: false).contains("vendored"))
  }

  @Test
  func unknownRefGivesNoView() async throws {
    try await fixture(local: "{}")
    #expect(await names(ref: "no-such-ref", copyIgnored: true, copyUntracked: true) == ["<no view>"])
  }

  @Test
  func notARepositoryGivesNoView() async {
    #expect(await names(copyIgnored: false, copyUntracked: true) == ["<no view>"])
  }
}
