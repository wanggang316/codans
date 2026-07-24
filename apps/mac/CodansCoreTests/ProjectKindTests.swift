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
  func projectWithRemoteHostIsServer() {
    let host = RemoteHost(alias: "example.com", username: "alice", port: 2222)
    // A remote git repo still classifies as `.server` — the remote/local axis
    // wins over the git/dir axis.
    let project = Project(name: "p", rootPath: "/srv/app", gitRoot: "/srv/app", remoteHost: host)
    #expect(project.kind == .server)
    #expect(project.isRemote)
  }

  @Test
  func rawValuesAreLowercaseTokens() {
    #expect(ProjectKind.gitRepo.rawValue == "git_repo")
    #expect(ProjectKind.dir.rawValue == "dir")
    #expect(ProjectKind.server.rawValue == "server")
  }
}
