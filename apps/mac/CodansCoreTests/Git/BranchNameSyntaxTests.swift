import Testing

@testable import CodansCore

struct BranchNameSyntaxTests {
  @Test
  func acceptsOrdinaryBranchNames() {
    for name in ["main", "feat/checkout-flow", "release/1.2", "fix_123", "a.b", "x/y/z"] {
      #expect(BranchNameSyntax.quickCheck(name) == nil, "\(name)")
    }
  }

  @Test
  func rejectsWhatGitWouldReject() {
    #expect(BranchNameSyntax.quickCheck("") == .empty)
    #expect(BranchNameSyntax.quickCheck("a b") == .whitespace)
    #expect(BranchNameSyntax.quickCheck("a\tb") == .whitespace)
    #expect(BranchNameSyntax.quickCheck("a..b") == .forbiddenSequence(".."))
    #expect(BranchNameSyntax.quickCheck("a@{b") == .forbiddenSequence("@{"))
    #expect(BranchNameSyntax.quickCheck("a:b") == .forbiddenSequence(":"))
    #expect(BranchNameSyntax.quickCheck("-x") == .badEdge("-"))
    #expect(BranchNameSyntax.quickCheck("/x") == .badEdge("/"))
    #expect(BranchNameSyntax.quickCheck("x/") == .badEdge("/"))
    #expect(BranchNameSyntax.quickCheck(".x") == .badEdge("."))
    #expect(BranchNameSyntax.quickCheck("x.") == .badEdge("."))
    #expect(BranchNameSyntax.quickCheck("x.lock") == .badEdge(".lock"))
    #expect(BranchNameSyntax.quickCheck("a//b") == .badEdge("//"))
    #expect(BranchNameSyntax.quickCheck("a/.b") == .badEdge("."))
    #expect(BranchNameSyntax.quickCheck("@") == .forbiddenSequence("@"))
    #expect(!BranchNameSyntax.isPlausible("bad name"))
  }
}
