import Foundation
import Testing

@testable import CodansCore

/// Pi's project trust, read from fixture agent directories.
struct PiProjectTrustTests {
  private let root: URL
  private let agent: URL
  private let project: URL

  init() throws {
    // `realpath` so the fixture paths match what Pi saves (`/private/var/...`).
    let temp = FileManager.default.temporaryDirectory
      .appending(path: "pi-trust-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    root = URL(fileURLWithPath: String(cString: realpath(temp.path(percentEncoded: false), nil)), isDirectory: true)
    agent = root.appending(path: "home/.pi/agent", directoryHint: .isDirectory)
    project = root.appending(path: "code/repo", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Saves trust decisions keyed by path, as Pi writes them.
  private func trust(_ entries: [(URL, Any)]) throws {
    var object: [String: Any] = [:]
    for (url, decision) in entries {
      var path = url.path(percentEncoded: false)
      if path.count > 1, path.hasSuffix("/") { path.removeLast() }
      object[path] = decision
    }
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object).write(to: agent.appending(path: "trust.json"))
  }

  private func trusts(_ arguments: String = "", start: URL? = nil, startExists: Bool = true) -> Bool {
    PiProjectTrust.trusts(
      agentDirectory: agent, extraArguments: arguments, start: start ?? project, startExists: startExists)
  }

  @Test
  func noSavedDecisionAsksSoProjectSkillsAreOff() {
    #expect(!trusts())
  }

  @Test
  func nearestSavedDecisionWins() throws {
    try trust([(project, true)])
    #expect(trusts())
    try trust([(project.deletingLastPathComponent(), true)])
    #expect(trusts())
    try trust([(project.deletingLastPathComponent(), true), (project, false)])
    #expect(!trusts())
    try trust([(project.deletingLastPathComponent(), false), (project, NSNull())])
    #expect(!trusts())
  }

  @Test
  func defaultProjectTrustAppliesWithoutASavedDecision() throws {
    try write(#"{"defaultProjectTrust": "always"}"#, to: agent.appending(path: "settings.json"))
    #expect(trusts())
    try write(#"{"defaultProjectTrust": "never"}"#, to: agent.appending(path: "settings.json"))
    #expect(!trusts())
  }

  @Test
  func approveFlagsComeFirst() throws {
    try trust([(project, false)])
    #expect(trusts("--approve"))
    #expect(trusts("-a"))
    try trust([(project, true)])
    #expect(!trusts("--no-approve"))
    #expect(!trusts("-na"))
  }

  @Test
  func extensionsThatCanDecideTrustTurnProjectSkillsOff() throws {
    try trust([(project, true)])
    #expect(!trusts("-e ./review.ts"))
    #expect(!trusts("--extension=./review.ts"))
    try write("export default {}", to: agent.appending(path: "extensions/review.ts"))
    #expect(!trusts())
    #expect(trusts("--no-extensions"))
    try FileManager.default.removeItem(at: agent.appending(path: "extensions"))
    try write(#"{"packages": ["npm:pi-tools"]}"#, to: agent.appending(path: "settings.json"))
    #expect(!trusts())
  }

  @Test
  func newWorktreeHasNoSavedDecisionYet() throws {
    try trust([(project.deletingLastPathComponent(), true)])
    #expect(!trusts(startExists: false))
    #expect(trusts("--approve", startExists: false))
  }

  @Test
  func unreadableInputsTurnProjectSkillsOff() throws {
    try trust([(project, true)])
    #expect(!trusts("--model 'x'"))
    try write(#"{"/x": "yes"}"#, to: agent.appending(path: "trust.json"))
    #expect(!trusts())
    try trust([(project, true)])
    try write("not json", to: agent.appending(path: "settings.json"))
    #expect(!trusts())
  }

  @Test
  func symlinkedStartMatchesTheRealPath() throws {
    try trust([(project, true)])
    let link = root.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
    #expect(trusts(start: link))
  }

  @Test
  func resolverListsPiProjectDirectoriesOnlyInATrustedProject() throws {
    let home = root.appending(path: "home")
    let profile = AgentProfile(kind: .pi)
    func projectSources() -> [AgentSkillSource] {
      SkillLocationResolver.directories(
        for: profile, projectStart: project, userHome: home, stateDirectory: root.appending(path: "state"),
        isRepositoryRoot: { $0.standardizedFileURL.path(percentEncoded: false).hasSuffix("/repo/") }
      ).map(\.source).filter { $0 == .project }
    }
    #expect(projectSources().isEmpty)
    try trust([(project, true)])
    #expect(projectSources().count == 2)
    let newWorktree = SkillLocationResolver.directories(
      for: profile, projectStart: project, excluding: ProjectFileExclusion(root: project, paths: []),
      userHome: home, stateDirectory: root.appending(path: "state"))
    #expect(!newWorktree.contains { $0.source == .project })
  }
}
