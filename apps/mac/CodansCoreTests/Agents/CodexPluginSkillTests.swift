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
  func pluginKeyThatLeavesTheCacheIsIgnored() {
    let config = """
      [plugins."../x@market"]
      enabled = true
      [plugins."docs@.."]
      enabled = true
      [plugins.'lit@market']
      enabled = true
      """
    #expect(
      CodexPluginRegistry.enabledPlugins(config: config) == [
        CodexPluginRegistry.Plugin(name: "lit", marketplace: "market")
      ])
  }
}
