import Foundation
import Testing

@testable import CodansCore

struct RemoteHeadsTests {
  @Test
  func parseReadsTheSymrefAndEveryBranch() {
    let output = """
      ref: refs/heads/main\tHEAD
      ae42c7a8e340fdd4a8bb41b0444007140eca7e3b\tHEAD
      ae42c7a8e340fdd4a8bb41b0444007140eca7e3b\trefs/heads/main
      1111111111111111111111111111111111111111\trefs/heads/feat/b
      2222222222222222222222222222222222222222\trefs/heads/feat/a
      3333333333333333333333333333333333333333\trefs/tags/v1
      4444444444444444444444444444444444444444\trefs/tags/v1^{}
      """
    let heads = RemoteHeads.parse(lsRemoteOutput: output)
    #expect(heads.defaultBranch == "main")
    #expect(heads.branches == ["feat/a", "feat/b", "main"])
  }

  @Test
  func parseToleratesNoSymrefAndEmptyOutput() {
    let heads = RemoteHeads.parse(lsRemoteOutput: "abc\trefs/heads/only\n")
    #expect(heads.defaultBranch == nil)
    #expect(heads.branches == ["only"])
    #expect(RemoteHeads.parse(lsRemoteOutput: "") == RemoteHeads())
    #expect(RemoteHeads.parse(lsRemoteOutput: "garbage without tabs\n") == RemoteHeads())
  }
}
