import AppKit
import CodansCore
import Testing

@testable import Codans

/// The missing-CLI row in Settings › Git Platforms: the warning text names only what is
/// missing, and the copy button puts only the install command on the pasteboard.
@MainActor
struct GitPlatformCLIInstallRowTests {
  @Test(arguments: GitPlatformKind.allCases)
  func warningTextDoesNotContainTheInstallCommand(_ kind: GitPlatformKind) {
    let message = GitPlatformsSettingsView.notInstalledMessage(kind)
    #expect(!message.contains(kind.installCommand))
    #expect(!message.contains("brew"))
    #expect(message.contains("(\(kind.cliName)) is not installed."))
  }

  @Test
  func gitLabWarningTextNamesTheCLI() {
    #expect(GitPlatformsSettingsView.notInstalledMessage(.gitlab) == "GitLab CLI (glab) is not installed.")
  }

  @Test(arguments: [(GitPlatformKind.github, "brew install gh"), (.gitlab, "brew install glab")])
  func copyPutsExactlyTheInstallCommandOnThePasteboard(_ kind: GitPlatformKind, _ expected: String) {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("codans.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("stale", forType: .string)

    CLIInstallCommandRow.copy(kind.installCommand, to: pasteboard)

    #expect(pasteboard.string(forType: .string) == expected)
    #expect(pasteboard.pasteboardItems?.count == 1)
  }
}
