import Foundation
import Testing

@testable import CodansCore

/// Plugin skills of a Claude Code profile, read from fixture config roots.
struct ClaudePluginSkillTests {
  private let home: URL
  private let stateRoot: URL
  /// Stands in for the machine-wide managed settings file.
  private let managed: URL
  private let project: URL

  init() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "claude-plugin-skills-\(UUID().uuidString)", directoryHint: .isDirectory)
    home = root.appending(path: "home", directoryHint: .isDirectory)
    stateRoot = root.appending(path: "state", directoryHint: .isDirectory)
    managed = root.appending(path: "managed/managed-settings.json")
    project = root.appending(path: "repo", directoryHint: .isDirectory)
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

  /// A config root with a user skill `mine`, plugin `docs` (skills/),
  /// plugin `pro` (.claude/skills), and plugin `off` installed but disabled.
  private func fixture(root configRoot: URL) throws {
    try skill("mine", in: configRoot.appending(path: "skills"))
    let cache = configRoot.appending(path: "plugins/cache")
    let docs = cache.appending(path: "market/docs/1.0.0")
    let pro = cache.appending(path: "other/pro/2.0.0")
    let off = cache.appending(path: "market/off/1.0.0")
    try skill("pdf", in: docs.appending(path: "skills"))
    try skill("design", in: pro.appending(path: ".claude/skills"))
    try skill("hidden", in: off.appending(path: "skills"))
    try write(
      """
      {"version": 2, "plugins": {
        "docs@market": [{"scope": "user", "installPath": "\(docs.path(percentEncoded: false))"}],
        "pro@other": [{"scope": "user", "installPath": "\(pro.path(percentEncoded: false))"}],
        "off@market": [{"scope": "user", "installPath": "\(off.path(percentEncoded: false))"}]
      }}
      """,
      to: configRoot.appending(path: "plugins/installed_plugins.json"))
    try write(
      """
      {"enabledPlugins": {"docs@market": true, "pro@other": true, "off@market": false}}
      """,
      to: configRoot.appending(path: "settings.json"))
  }

  private func plugins(_ profile: AgentProfile, in projectDirectory: URL? = nil) -> [SkillDirectory] {
    SkillLocationResolver.pluginDirectories(
      for: profile, projectDirectory: projectDirectory, userHome: home, stateDirectory: stateRoot,
      managedSettings: managed)
  }

  private func scan(_ profile: AgentProfile, in projectDirectory: URL? = nil) -> [AgentSkillEntry] {
    SkillScanner.scanSync(
      SkillLocationResolver.userDirectories(for: profile, userHome: home, stateDirectory: stateRoot)
        + plugins(profile, in: projectDirectory))
  }

  private func enable(_ flags: String, in file: URL) throws {
    try write(#"{"enabledPlugins": {\#(flags)}}"#, to: file)
  }

  @Test
  func claudeCodeLocationUsesTheClaudeCodePluginSource() {
    #expect(AgentCatalog.descriptor(for: .claudeCode).skillLocation.plugins == .claudeCode)
    for kind in AgentKind.allCases where kind != .claudeCode {
      #expect(AgentCatalog.descriptor(for: kind).skillLocation.plugins == nil, "\(kind)")
    }
  }

  @Test
  func enabledPluginsInBothLayoutsAreListedAsPluginColonSkill() throws {
    try fixture(root: home.appending(path: ".claude"))
    let entries = scan(AgentProfile(kind: .claudeCode))
    #expect(entries.map(\.name) == ["docs:pdf", "mine", "pro:design"])
    #expect(entries.map(\.source) == [.plugin, .user, .plugin])
    #expect(entries.first?.summary == "pdf skill.")
  }

  @Test
  func disabledPluginIsNotListed() throws {
    try fixture(root: home.appending(path: ".claude"))
    #expect(!scan(AgentProfile(kind: .claudeCode)).contains { $0.name.hasPrefix("off:") })
  }

  @Test
  func missingOrMalformedRegistryOrSettingsLeavesUserSkillsUnchanged() throws {
    let root = home.appending(path: ".claude")
    let registry = root.appending(path: "plugins/installed_plugins.json")
    let settings = root.appending(path: "settings.json")
    let profile = AgentProfile(kind: .claudeCode)
    let cases: [(URL, String?)] = [
      (registry, nil), (settings, nil), (registry, "{not json"), (settings, "[1, 2"),
      (registry, #"{"plugins": ["docs@market"]}"#), (settings, #"{"enabledPlugins": "all"}"#),
    ]
    for (file, contents) in cases {
      try fixture(root: root)
      if let contents {
        try write(contents, to: file)
      } else {
        try FileManager.default.removeItem(at: file)
      }
      let entries = scan(profile)
      #expect(entries.filter { $0.source == .user }.map(\.name) == ["mine"], "\(file.lastPathComponent)")
      #expect(entries.allSatisfy { $0.source == .user }, "\(file.lastPathComponent) \(contents ?? "missing")")
    }
  }

  @Test
  func pluginsResolveUnderTheDedicatedHome() throws {
    let profile = AgentProfile(kind: .claudeCode, usesDedicatedHome: true)
    let dedicated = AgentLaunchCommand.dedicatedHomeURL(for: profile, stateDirectory: stateRoot)
    try fixture(root: home.appending(path: ".claude"))
    #expect(scan(profile).isEmpty)
    try fixture(root: dedicated.appending(path: ".claude"))
    #expect(scan(profile).map(\.name) == ["docs:pdf", "mine", "pro:design"])
  }

  @Test
  func pluginsResolveUnderTheConfigRootVariable() throws {
    let configRoot = home.appending(path: "work-claude")
    try fixture(root: configRoot)
    let profile = AgentProfile(
      kind: .claudeCode, envVars: ["CLAUDE_CONFIG_DIR": configRoot.path(percentEncoded: false)])
    #expect(scan(profile).map(\.name) == ["docs:pdf", "mine", "pro:design"])
    #expect(scan(AgentProfile(kind: .claudeCode)).isEmpty)
    let relative = AgentProfile(kind: .claudeCode, envVars: ["CLAUDE_CONFIG_DIR": "work-claude"])
    #expect(plugins(relative).isEmpty)
  }

  @Test
  func pluginDirectoriesCoverBothLayoutsUnderTheResolvedRoot() throws {
    try fixture(root: home.appending(path: "alt"))
    let profile = AgentProfile(kind: .claudeCode, envVars: ["CLAUDE_CONFIG_DIR": "~/alt"])
    let directories = plugins(profile)
    let docs = home.appending(path: "alt/plugins/cache/market/docs/1.0.0").standardizedFileURL
    #expect(
      directories.filter { $0.namespace == "docs" }.map(\.url) == [
        docs.appending(path: "skills", directoryHint: .isDirectory),
        docs.appending(path: ".claude/skills", directoryHint: .isDirectory),
      ])
    #expect(directories.allSatisfy { $0.source == .plugin })
  }

  @Test
  func manifestSkillPathsReplaceTheWholeClaudeSkillsFolder() throws {
    let root = home.appending(path: ".claude")
    try fixture(root: root)
    let pro = root.appending(path: "plugins/cache/other/pro/2.0.0")
    try skill("extra", in: pro.appending(path: ".claude/skills"))
    try skill("bundled", in: pro.appending(path: "more"))
    try skill("outside", in: home.appending(path: "elsewhere"))
    try write(
      #"{"name": "pro", "skills": ["./.claude/skills/design", "./more", "../../../../../../elsewhere", "/abs"]}"#,
      to: pro.appending(path: ".claude-plugin/plugin.json"))
    let names = scan(AgentProfile(kind: .claudeCode)).map(\.name)
    #expect(names == ["docs:pdf", "mine", "pro:bundled", "pro:design"])
  }

  @Test
  func manifestWithoutSkillsKeepsBothLayouts() throws {
    let root = home.appending(path: ".claude")
    try fixture(root: root)
    try write(
      #"{"name": "pro"}"#,
      to: root.appending(path: "plugins/cache/other/pro/2.0.0/.claude-plugin/plugin.json"))
    #expect(scan(AgentProfile(kind: .claudeCode)).map(\.name) == ["docs:pdf", "mine", "pro:design"])
  }

  @Test
  func projectSettingsEnableAPluginTheUserDisabled() throws {
    try fixture(root: home.appending(path: ".claude"))
    try enable(#""off@market": true"#, in: project.appending(path: ".claude/settings.json"))
    let profile = AgentProfile(kind: .claudeCode)
    #expect(scan(profile, in: project).map(\.name) == ["docs:pdf", "mine", "off:hidden", "pro:design"])
    #expect(!scan(profile).contains { $0.name == "off:hidden" })
  }

  @Test
  func projectSettingsDisableAPluginTheUserEnabled() throws {
    try fixture(root: home.appending(path: ".claude"))
    try enable(#""docs@market": false"#, in: project.appending(path: ".claude/settings.json"))
    #expect(scan(AgentProfile(kind: .claudeCode), in: project).map(\.name) == ["mine", "pro:design"])
  }

  @Test
  func localSettingsWinOverProjectSettings() throws {
    try fixture(root: home.appending(path: ".claude"))
    try enable(#""docs@market": false, "off@market": true"#, in: project.appending(path: ".claude/settings.json"))
    try enable(#""docs@market": true, "off@market": false"#, in: project.appending(path: ".claude/settings.local.json"))
    #expect(scan(AgentProfile(kind: .claudeCode), in: project).map(\.name) == ["docs:pdf", "mine", "pro:design"])
  }

  @Test
  func managedSettingsWinOverEveryOtherFile() throws {
    try fixture(root: home.appending(path: ".claude"))
    try enable(#""off@market": true"#, in: project.appending(path: ".claude/settings.local.json"))
    try enable(#""off@market": false, "pro@other": false"#, in: managed)
    #expect(scan(AgentProfile(kind: .claudeCode), in: project).map(\.name) == ["docs:pdf", "mine"])
  }

  @Test
  func malformedProjectSettingsAreSkipped() throws {
    try fixture(root: home.appending(path: ".claude"))
    try write("{not json", to: project.appending(path: ".claude/settings.json"))
    try enable(#""off@market": true"#, in: project.appending(path: ".claude/settings.local.json"))
    #expect(scan(AgentProfile(kind: .claudeCode), in: project).map(\.name) == ["docs:pdf", "mine", "off:hidden", "pro:design"])
  }

  @Test
  func projectSettingsEnableAPluginWithoutUserSettings() throws {
    let root = home.appending(path: ".claude")
    try fixture(root: root)
    try FileManager.default.removeItem(at: root.appending(path: "settings.json"))
    try enable(#""docs@market": true"#, in: project.appending(path: ".claude/settings.json"))
    #expect(scan(AgentProfile(kind: .claudeCode), in: project).map(\.name) == ["docs:pdf", "mine"])
  }

  @Test
  func settingsFlagFileWinsOverProjectSettingsButNotManagedSettings() throws {
    try fixture(root: home.appending(path: ".claude"))
    let flagFile = home.appending(path: "flag-settings.json")
    try enable(#""docs@market": true"#, in: project.appending(path: ".claude/settings.local.json"))
    try enable(#""docs@market": false, "off@market": true, "pro@other": true"#, in: flagFile)
    try enable(#""pro@other": false"#, in: managed)
    let profile = AgentProfile(
      kind: .claudeCode, extraArguments: "--verbose --settings \(flagFile.path(percentEncoded: false))")
    #expect(scan(profile, in: project).map(\.name) == ["mine", "off:hidden"])
  }

  @Test
  func settingsFlagPathFormsResolve() {
    let user = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    func read(_ arguments: String, in directory: URL? = project) -> ClaudePluginRegistry.LaunchSettings {
      ClaudePluginRegistry.launchSettings(
        extraArguments: arguments, projectDirectory: directory, userHome: user)
    }
    #expect(read("") == .none)
    #expect(read("--model opus --verbose") == .none)
    #expect(read("--settings /etc/claude.json") == .file(URL(fileURLWithPath: "/etc/claude.json")))
    #expect(read("--settings=/etc/claude.json") == .file(URL(fileURLWithPath: "/etc/claude.json")))
    #expect(read("--settings ~/c.json") == .file(URL(fileURLWithPath: "/Users/me/c.json")))
    #expect(
      read("--settings conf/c.json")
        == .file(project.appending(path: "conf/c.json").standardizedFileURL))
    #expect(read("--settings conf/c.json", in: nil) == .unknown)
  }

  @Test
  func unreadableSettingsFlagsOfferNoPluginSkills() throws {
    try fixture(root: home.appending(path: ".claude"))
    let unknown = [
      #"--settings '{"enabledPlugins":{}}'"#, "--settings \"/tmp/a b.json\"", "--settings $CONF",
      "--settings", "--settings /a.json --settings /b.json", "--setting-sources user",
      "--setting-sources=user,project", "--plugin-dir ./dev-plugin", "--settings ~other/c.json",
    ]
    for arguments in unknown {
      let profile = AgentProfile(kind: .claudeCode, extraArguments: arguments)
      #expect(scan(profile, in: project).map(\.name) == ["mine"], "\(arguments)")
    }
  }

  @Test
  func agentWithoutPluginSourceReadsNoRegistry() throws {
    try fixture(root: home.appending(path: ".claude"))
    #expect(plugins(AgentProfile(kind: .codex)).isEmpty)
  }
}
