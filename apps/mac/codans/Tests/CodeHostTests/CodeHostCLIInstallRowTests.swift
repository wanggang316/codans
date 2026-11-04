import AppKit
import CodansCore
import Testing

@testable import Codans

/// The missing-CLI row in Settings › Code Hosts: the warning text names only what is
/// missing, and the copy button puts only the install command on the pasteboard.
@MainActor
struct CodeHostCLIInstallRowTests {
  @Test(arguments: CodeHostKind.allCases)
  func warningTextDoesNotContainTheInstallCommand(_ kind: CodeHostKind) {
    let message = CodeHostsSettingsView.notInstalledMessage(kind)
    #expect(!message.contains(kind.installCommand))
    #expect(!message.contains("brew"))
    #expect(message.contains("(\(kind.cliName)) is not installed."))
  }

  @Test
  func gitLabWarningTextNamesTheCLI() {
    #expect(CodeHostsSettingsView.notInstalledMessage(.gitlab) == "GitLab CLI (glab) is not installed.")
  }

  @Test(arguments: [(CodeHostKind.github, "brew install gh"), (.gitlab, "brew install glab")])
  func copyPutsExactlyTheInstallCommandOnThePasteboard(_ kind: CodeHostKind, _ expected: String) {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("codans.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("stale", forType: .string)

    CLIInstallCommandRow.copy(kind.installCommand, to: pasteboard)

    #expect(pasteboard.string(forType: .string) == expected)
    #expect(pasteboard.pasteboardItems?.count == 1)
  }
}
