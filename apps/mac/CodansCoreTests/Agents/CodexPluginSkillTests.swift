import Foundation
import Testing

@testable import CodansCore

/// Plugin skills of a Codex profile, read from fixture config roots.
struct CodexPluginSkillTests {
  private let home: URL
  private let stateRoot: URL

  init() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "codex-plugin-skills-\(UUID().uuidString)", directoryHint: .isDirectory)
    home = root.appending(path: "home", directoryHint: .isDirectory)
    stateRoot = root.appending(path: "state", directoryHint: .isDirectory)
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

  private static let enabledConfig = """
    model = "gpt-5.1-codex"

    [plugins."docs@market"]
    enabled = true # on

    [plugins."off@market"]
    enabled = false

    [plugins."bare@market"]

    [projects."/code/repo"]
    enabled = true
    """

  /// A config root with a user skill `mine`, enabled plugin `docs`, disabled
  /// plugin `off`, plugin `bare` with no `enabled`, and plugin `stray` that
  /// the config does not name.
  private func fixture(root configRoot: URL, config: String = enabledConfig) throws {
    try skill("mine", in: configRoot.appending(path: "skills"))
    let cache = configRoot.appending(path: "plugins/cache/market")
    try skill("pdf", in: cache.appending(path: "docs/1.0.0/skills"))
    try skill("hidden", in: cache.appending(path: "off/1.0.0/skills"))
    try skill("plain", in: cache.appending(path: "bare/1.0.0/skills"))
    try skill("stray", in: cache.appending(path: "stray/1.0.0/skills"))
    try write(config, to: configRoot.appending(path: "config.toml"))
  }

  private func scan(_ profile: AgentProfile) -> [AgentSkillEntry] {
    SkillScanner.scanSync(
      SkillLocationResolver.directories(
        for: profile, projectStart: nil, userHome: home, stateDirectory: stateRoot),
      precedence: profile.descriptor.skillLocation.precedence)
  }

  @Test
  func codexLocationUsesTheCodexPluginSource() {
    #expect(SkillLocation.codex.plugins == .codex)
  }

  @Test
  func enabledPluginSkillsAreListedAndDisabledOnesAreNot() throws {
    try fixture(root: home.appending(path: ".codex"))
    let skills = scan(AgentProfile(kind: .codex))
    #expect(skills.map(\.name) == ["docs:pdf", "mine"])
    #expect(skills.first?.source == .plugin)
  }

  @Test
  func pluginSkillIsCalledWithTheDollarSpelling() throws {
    try fixture(root: home.appending(path: ".codex"))
    let plugin = try #require(scan(AgentProfile(kind: .codex)).first { $0.source == .plugin })
    #expect(SkillLocation.codex.invocationStyle.token(for: plugin.name) == "$docs:pdf")
  }

  @Test
  func codexHomeMovesThePluginRegistry() throws {
    let moved = home.appending(path: "work-codex")
    try fixture(root: moved)
    let profile = AgentProfile(kind: .codex, envVars: ["CODEX_HOME": moved.path(percentEncoded: false)])
    #expect(scan(profile).map(\.name) == ["docs:pdf", "mine"])
    #expect(scan(AgentProfile(kind: .codex)).isEmpty)
  }

  @Test
  func newestCachedVersionKeepsTheName() throws {
    let root = home.appending(path: ".codex")
    try fixture(root: root)
    let docs = root.appending(path: "plugins/cache/market/docs")
    try write(
      "---\nname: pdf\ndescription: Newer.\n---\n", to: docs.appending(path: "1.10.0/skills/pdf/SKILL.md"))
    let pdf = try #require(scan(AgentProfile(kind: .codex)).first { $0.name == "docs:pdf" })
    #expect(pdf.summary == "Newer.")
  }

  @Test
  func missingOrUnreadableConfigGivesNoPluginSkills() throws {
    let root = home.appending(path: ".codex")
    try fixture(root: root)
    try FileManager.default.removeItem(at: root.appending(path: "config.toml"))
    #expect(scan(AgentProfile(kind: .codex)).map(\.name) == ["mine"])
  }

  @Test
  func pluginKeyThatLeavesTheCacheGivesNoPlugins() {
    #expect(CodexPluginRegistry.enabledPlugins(layers: ["[plugins.\"../x@market\"]\nenabled = true"]) == nil)
    #expect(CodexPluginRegistry.enabledPlugins(layers: ["[plugins.\"docs@..\"]\nenabled = true"]) == nil)
    #expect(
      CodexPluginRegistry.enabledPlugins(layers: ["[plugins.'lit@market']\nenabled = true"]) == [
        CodexPluginRegistry.Plugin(name: "lit", marketplace: "market")
      ])
  }

  // MARK: - Overrides

  private func codexHome() throws -> URL {
    let root = home.appending(path: ".codex")
    try fixture(root: root)
    return root
  }

  /// Plugin skills for `profile` started in `projectStart`, with `home/repo`
  /// as the repository root.
  private func scan(_ profile: AgentProfile, in projectStart: URL) -> [AgentSkillEntry] {
    let repo = Self.trimmedPath(home.appending(path: "repo"))
    return SkillScanner.scanSync(
      SkillLocationResolver.pluginDirectories(
        for: profile, projectStart: projectStart, userHome: home, stateDirectory: stateRoot,
        isRepositoryRoot: { Self.trimmedPath($0) == repo }))
  }

  private static func trimmedPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  private func pluginNames(_ extraArguments: String) -> [String] {
    scan(AgentProfile(kind: .codex, extraArguments: extraArguments)).filter { $0.source == .plugin }.map(\.name)
  }

  @Test
  func profileLayerDecidesOverTheBaseConfig() throws {
    let root = try codexHome()
    try write(
      "[plugins.\"docs@market\"]\nenabled = false\n[plugins.\"off@market\"]\nenabled = true\n",
      to: root.appending(path: "work.config.toml"))
    #expect(pluginNames("-p work") == ["off:hidden"])
    #expect(pluginNames("--profile work") == ["off:hidden"])
    #expect(pluginNames("--profile=work") == ["off:hidden"])
    #expect(pluginNames("") == ["docs:pdf"])
  }

  @Test
  func missingOrRepeatedProfileGivesNoPluginSkills() throws {
    _ = try codexHome()
    #expect(pluginNames("-p absent").isEmpty)
    try write("", to: home.appending(path: ".codex/a.config.toml"))
    #expect(pluginNames("-p a -p a").isEmpty)
    #expect(pluginNames("-p").isEmpty)
    #expect(pluginNames("-p ../a").isEmpty)
  }

  @Test
  func pluginsFeatureTurnsEveryPluginOff() throws {
    let root = try codexHome()
    #expect(pluginNames("--disable plugins").isEmpty)
    #expect(pluginNames("--disable other") == ["docs:pdf"])
    try write(Self.enabledConfig + "\n[features]\nplugins = false\n", to: root.appending(path: "config.toml"))
    #expect(pluginNames("").isEmpty)
    #expect(pluginNames("--enable plugins") == ["docs:pdf"])
  }

  @Test
  func overridesCodansCannotReadGiveNoPluginSkills() throws {
    _ = try codexHome()
    for arguments in [
      "-c features.plugins=false", "--config=x=1", "-cx=1", "--remote ws://host", "-C /tmp", "--cd=/tmp",
      "--model 'gpt'", "$FLAGS",
    ] {
      #expect(pluginNames(arguments).isEmpty, "\(arguments)")
    }
    #expect(pluginNames("--model gpt-5.1 --search") == ["docs:pdf"])
  }

  @Test
  func configFormsCodansDoesNotReadGiveNoPluginSkills() throws {
    let root = try codexHome()
    for extra in [
      "[plugins]\n\"docs@market\" = { enabled = false }", "[plugins.\"docs@market\"]\nenabled = \"no\"",
    ] {
      try write(Self.enabledConfig + "\n" + extra + "\n", to: root.appending(path: "config.toml"))
      #expect(pluginNames("").isEmpty, "\(extra)")
    }
    try write(
      "plugins.\"docs@market\".enabled = false\n" + Self.enabledConfig, to: root.appending(path: "config.toml"))
    #expect(pluginNames("").isEmpty)
  }

  @Test
  func projectConfigAboutPluginsGivesNoPluginSkills() throws {
    _ = try codexHome()
    let repo = home.appending(path: "repo")
    let profile = AgentProfile(kind: .codex)
    try write("model = \"gpt-5.1\"\n", to: repo.appending(path: ".codex/config.toml"))
    #expect(scan(profile, in: repo.appending(path: "apps")).map(\.name) == ["docs:pdf"])
    try write("[features]\nplugins = true\n", to: repo.appending(path: ".codex/config.toml"))
    #expect(scan(profile, in: repo.appending(path: "apps")).isEmpty)
  }

  @Test
  func launchConfigReadsOnlyPlainArguments() {
    #expect(CodexPluginRegistry.launchConfig(extraArguments: "") == .known(profile: nil, plugins: nil))
    #expect(
      CodexPluginRegistry.launchConfig(extraArguments: "-pwork --disable=plugins")
        == .known(profile: "work", plugins: false))
    #expect(CodexPluginRegistry.launchConfig(extraArguments: "--search \"x\"") == .unknown)
  }
}
