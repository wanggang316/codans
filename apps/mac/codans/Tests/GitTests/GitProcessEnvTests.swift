import Foundation
import Testing

@testable import Codans

struct GitProcessEnvTests {
  @Test
  func allowlistedKeysPropagate() {
    let env = GitProcessEnv.build(from: [
      "PATH": "/usr/bin:/bin",
      "HOME": "/Users/test",
    ])
    #expect(env["PATH"] == "/usr/bin:/bin")
    #expect(env["HOME"] == "/Users/test")
  }

  @Test
  func forcedLCALLAlwaysPresent() {
    let env = GitProcessEnv.build(from: ["PATH": "/usr/bin"])
    #expect(env["LC_ALL"] == "C.UTF-8")
  }

  @Test
  func shellIsStrippedEvenWhenSetInParent() {
    let env = GitProcessEnv.build(from: [
      "PATH": "/usr/bin",
      "SHELL": "/bin/zsh",
    ])
    #expect(env["SHELL"] == nil)
  }

  @Test
  func forbiddenGitVariablesStripped() {
    let env = GitProcessEnv.build(from: [
      "PATH": "/usr/bin",
      "GIT_DIR": "/tmp/custom.git",
      "GIT_EXTERNAL_DIFF": "/usr/local/bin/evil",
      "GIT_ASKPASS": "/usr/local/bin/sneaky",
      "GIT_EDITOR": "/bin/vim",
    ])
    for key in GitProcessEnv.forbidden {
      #expect(env[key] == nil, "forbidden key '\(key)' leaked into child env")
    }
  }

  @Test
  func resultContainsOnlyAllowlistAndForced() {
    let env = GitProcessEnv.build(from: [
      "PATH": "/usr/bin",
      "HOME": "/Users/test",
      "SHELL": "/bin/zsh",
      "EDITOR": "/bin/vim",
      "TERM": "xterm-256color",
      "GIT_DIR": "/tmp",
    ])
    let expectedKeys: Set<String> = ["PATH", "HOME", "LC_ALL"]
    #expect(Set(env.keys) == expectedKeys)
  }

  @Test
  func missingAllowlistedKeysOmittedRatherThanEmpty() {
    let env = GitProcessEnv.build(from: [:])
    #expect(env["PATH"] == nil)
    #expect(env["HOME"] == nil)
    #expect(env["LC_ALL"] == "C.UTF-8")
  }

  @Test
  func inheritingDropsEveryGitKeyKeepsTheRestAndForcesPromptAndLocale() {
    var parent = Dictionary(uniqueKeysWithValues: GitProcessEnv.forbidden.map { ($0, "/parent") })
    parent["GIT_INDEX_FILE"] = "/parent/index"
    parent["GIT_TERMINAL_PROMPT"] = "1"
    parent["LC_ALL"] = "fr_FR.UTF-8"
    parent["SSH_AUTH_SOCK"] = "/tmp/agent.sock"
    parent["HTTPS_PROXY"] = "http://proxy:8080"
    parent["HOME"] = "/Users/test"
    let env = GitProcessEnv.inheriting(from: parent)
    #expect(env.keys.filter { $0.hasPrefix("GIT_") } == ["GIT_TERMINAL_PROMPT"])
    #expect(env["GIT_TERMINAL_PROMPT"] == "0")
    #expect(env["LC_ALL"] == "C.UTF-8")
    #expect(env["SSH_AUTH_SOCK"] == "/tmp/agent.sock")
    #expect(env["HTTPS_PROXY"] == "http://proxy:8080")
    #expect(env["HOME"] == "/Users/test")
  }
}
