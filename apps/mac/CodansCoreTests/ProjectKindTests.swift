import Foundation
import Testing

@testable import CodansCore

struct ProjectKindTests {
  @Test
  func projectWithGitRootIsGitRepo() {
    let project = Project(name: "p", rootPath: "/tmp/p", gitRoot: "/tmp/p")
    #expect(project.kind == .gitRepo)
  }

  @Test
  func projectWithoutGitRootIsDir() {
    let project = Project(name: "p", rootPath: "/tmp/p", gitRoot: nil)
    #expect(project.kind == .dir)
  }

  @Test
  func rawValuesAreLowercaseTokens() {
    #expect(ProjectKind.gitRepo.rawValue == "git_repo")
    #expect(ProjectKind.dir.rawValue == "dir")
  }
}
