import Foundation
import Testing

@testable import Codans

/// Clone failures from missing or rejected credentials get a next step that
/// names the host; git's own output stays as the detail. Other failures keep
/// git's output as the message.
struct CloneFailureTests {
  private func classify(_ stderr: String, remote: String) -> CloneFailure {
    CloneFailure(stderr: stderr, remoteURL: remote)
  }

  @Test(arguments: [
    "fatal: could not read Username for 'https://github.com': Device not configured",
    "fatal: could not read Username for 'https://github.com': terminal prompts disabled",
    "remote: Invalid username or password.\nfatal: Authentication failed for 'https://github.com/o/r.git/'",
    "fatal: unable to access 'https://github.com/o/r.git/': The requested URL returned error: 403",
  ])
  func httpCredentialFailureOnGitHubSuggestsGhAuthLogin(stderr: String) {
    let failure = classify(stderr, remote: "https://github.com/o/r.git")
    #expect(failure.summary.contains("github.com"))
    #expect(failure.summary.contains("Run `gh auth login` in a terminal"))
    #expect(failure.detail == stderr)
  }

  /// `gh auth login` without `--hostname` signs in to github.com only.
  @Test
  func httpCredentialFailureOnGitHubEnterpriseNamesTheHost() {
    let stderr = "fatal: Authentication failed for 'https://github.example.com/o/r.git/'"
    let failure = classify(stderr, remote: "https://github.example.com/o/r.git")
    #expect(failure.summary.contains("gh auth login --hostname github.example.com"))
  }

  @Test
  func terminalPromptsDisabledAloneIsACredentialFailure() {
    let stderr = "fatal: unable to get password from user: terminal prompts disabled"
    let failure = classify(stderr, remote: "https://git.example.com/o/r.git")
    #expect(failure.summary.contains("git.example.com"))
    #expect(failure.summary.contains("credential helper"))
    #expect(failure.detail == stderr)
  }

  /// Same rule as `GitPlatformResolver.kind(byName:)`: a host that names both
  /// platforms is neither.
  @Test
  func hostNamingBothPlatformsGetsTheCredentialHelperStep() {
    let stderr = "fatal: Authentication failed for 'https://github-gitlab-mirror.example.com/o/r.git/'"
    let failure = classify(stderr, remote: "https://github-gitlab-mirror.example.com/o/r.git")
    #expect(failure.summary.contains("credential helper"))
  }

  @Test
  func httpCredentialFailureOnGitLabSuggestsGlabWithTheHost() {
    let stderr = "fatal: unable to access 'https://gitlab.example.com/o/r.git/': The requested URL returned error: 401"
    let failure = classify(stderr, remote: "https://gitlab.example.com/o/r.git")
    #expect(failure.summary.contains("glab auth login --hostname gitlab.example.com"))
    #expect(failure.detail == stderr)
  }

  @Test
  func httpCredentialFailureOnOtherHostSuggestsACredentialHelper() {
    let stderr = "fatal: could not read Username for 'http://192.168.2.158:8929': Device not configured"
    let failure = classify(stderr, remote: "http://192.168.2.158:8929/team/app.git")
    #expect(failure.summary.contains("192.168.2.158:8929"))
    #expect(failure.summary.contains("credential helper"))
    #expect(!failure.summary.contains("gh auth"))
    #expect(!failure.summary.contains("glab"))
    #expect(failure.detail == stderr)
  }

  @Test
  func sshPublicKeyRejectionSuggestsAddingTheKey() {
    let stderr = "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository."
    let failure = classify(stderr, remote: "git@github.com:o/r.git")
    #expect(failure.summary.contains("github.com"))
    #expect(failure.summary.contains("SSH key"))
    #expect(failure.detail == stderr)
  }

  @Test
  func sshHostKeyFailureSuggestsAcceptingTheHostKeyInATerminal() {
    let stderr = "Host key verification failed.\nfatal: Could not read from remote repository."
    let failure = classify(stderr, remote: "ssh://git@git.example.com:2222/o/r.git")
    #expect(failure.summary.contains("git.example.com"))
    #expect(failure.summary.contains("ssh -p 2222 -T git@git.example.com"))
    #expect(failure.detail == stderr)
  }

  @Test
  func unknownFailureKeepsTheRawMessage() {
    let stderr = "fatal: repository 'https://github.com/o/missing.git/' not found\n"
    let failure = classify(stderr, remote: "https://github.com/o/missing.git")
    #expect(failure.summary == "fatal: repository 'https://github.com/o/missing.git/' not found")
    #expect(failure.detail == nil)
  }

  @Test
  func emptyOutputFallsBackToAGenericMessage() {
    #expect(classify("  \n", remote: "https://github.com/o/r.git").summary == "git clone failed.")
  }
}
