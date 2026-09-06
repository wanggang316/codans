import Foundation
import Testing

@testable import CodansCore

/// The store writes files and the kickoff prompt names them; both must agree
/// on the layout or a rename in one silently strands the other.
struct HandoffLayoutTests {
  private let store = HandoffStore(rootURL: URL(fileURLWithPath: "/repo/worktree", isDirectory: true))

  @Test
  func promptPathsResolveToTheFilesTheStoreWrites() {
    #expect(store.currentURL.path == "/repo/worktree/\(HandoffKickoff.currentPath)")
    #expect(store.contextURL.path == "/repo/worktree/\(HandoffKickoff.contextPath)")
    // The archive is quoted with a trailing slash so it reads as a directory.
    #expect(HandoffKickoff.archivePath.hasSuffix("/"))
    #expect(store.archiveDirectory.path == "/repo/worktree/" + HandoffKickoff.archivePath.dropLast())
  }

  @Test
  func promptPathsAreWorktreeRelative() {
    // The receiver runs from the worktree root, so no leading slash or `~`.
    for path in [HandoffKickoff.currentPath, HandoffKickoff.contextPath, HandoffKickoff.archivePath] {
      #expect(path.hasPrefix(HandoffLayout.worktreeRelativeDirectory + "/"))
      #expect(!path.hasPrefix("/"))
    }
  }

  @Test
  func storeRelativePathsAreRootedAtTheWorktree() {
    // Same base as the kickoff prompt: IPC payloads and `context.md` quote
    // paths an agent can open from the worktree root as written.
    #expect(
      store.relativePath(of: store.currentURL) == HandoffLayout.worktreeRelativePath(HandoffLayout.briefingFileName))
    #expect(store.ignoreURL == store.stateDirectory.appending(path: HandoffLayout.ignoreFileName))
  }
}
