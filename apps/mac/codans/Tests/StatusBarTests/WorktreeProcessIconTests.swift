import CodansCore
import Testing

@testable import Codans

@MainActor
struct WorktreeProcessIconTests {
  @Test(arguments: [
    ("npm run tauri dev", "npm"), ("npx", "npm"), ("pnpm run dev", "pnpm"),
    ("node", "nodejs"), ("nodejs", "nodejs"), ("python", "python"),
    ("python3.13", "python"), ("go", "go"), ("cargo", "rust"), ("rustc", "rust"),
    ("docker-compose", "docker"), ("docker", "docker"), ("git", "git"),
    ("/opt/homebrew/bin/vite", "vite"), ("bun", "bun"), ("terraform", "terraform"),
  ])
  func recognizesExecutableAndProcessTitles(input: String, mark: String) {
    #expect(
      WorktreeProcessIcon.resolve(processName: input, agentKind: nil) == .command(.mark(ToolMark(rawValue: mark)!)))
  }

  @Test(arguments: ["", "handbox", "python-server", "git-helper", "my-npm", "echo npm"])
  func unrelatedProcessesUseTerminal(input: String) {
    #expect(WorktreeProcessIcon.resolve(processName: input, agentKind: nil) == .terminal)
  }

  @Test func agentIdentityTakesPriorityOverNodeWrapper() {
    #expect(WorktreeProcessIcon.resolve(processName: "node", agentKind: .codex) == .agent(.codex))
  }
}
