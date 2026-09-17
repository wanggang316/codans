import CodansCore
import Testing

@testable import Codans

struct DiffFileTreeTests {
  @Test func groupsNestedFilesWithoutLosingTheirOriginalIdentity() throws {
    let first = GitComparisonFile(path: "Sources/App/View.swift", status: "M")
    let second = GitComparisonFile(path: "Tests/App/View.swift", status: "A")
    let tree = DiffFileTreeNode.build([second, first])
    #expect(tree.map(\.name) == ["Sources", "Tests"])
    #expect(tree[0].id == "dir:Sources")
    let app = try #require(tree[0].children?.first)
    #expect(app.id == "dir:Sources/App")
    #expect(app.path == "Sources/App")
    let leaf = try #require(app.children?.first)
    #expect(leaf.id == "file:\(first.id)")
    #expect(leaf.name == "View.swift")
    #expect(leaf.file == first)
    #expect(leaf.children == nil)
    #expect(tree[1].children?.first?.children?.first?.file == second)
  }

  @Test func sortsDirectoriesBeforeFilesAndUsesNaturalNameOrder() {
    let files = ["file10.swift", "z/nested.swift", "file2.swift", "a/nested.swift"].map {
      GitComparisonFile(path: $0, status: "M")
    }
    let tree = DiffFileTreeNode.build(files)
    #expect(tree.map(\.name) == ["a", "z", "file2.swift", "file10.swift"])
    #expect(tree == DiffFileTreeNode.build(Array(files.reversed())))
  }

  @Test func preservesDeletedAndRenamedFilesWithoutReadingTheFilesystem() {
    let deleted = GitComparisonFile(path: "gone/file.swift", status: "D", newMode: "000000")
    let renamed = GitComparisonFile(path: "new/file.swift", oldPath: "old/file.swift", status: "R")
    let tree = DiffFileTreeNode.build([renamed, deleted])
    #expect(tree.map(\.path) == ["gone", "new"])
    #expect(tree[0].children?.first?.file == deleted)
    #expect(tree[1].children?.first?.file == renamed)
  }

  @Test func preservesUnicodeWhitespaceAndFileToDirectoryTransitions() throws {
    let unusual = GitComparisonFile(path: "目录/odd\tname.swift", status: "A")
    let deleted = GitComparisonFile(path: "目录", status: "D")
    let tree = DiffFileTreeNode.build([deleted, unusual])
    #expect(tree.count == 2)
    #expect(tree[0].id == "dir:目录")
    #expect(tree[1].id == "file:\(deleted.id)")
    let leaf = try #require(tree[0].children?.first)
    #expect(leaf.name == "odd\tname.swift")
    #expect(leaf.path == unusual.path)
    #expect(leaf.file == unusual)
  }

  @Test func directoryAndFileIdentitiesCannotCollide() {
    let tree = DiffFileTreeNode.build([
      GitComparisonFile(path: "foo/a.swift", status: "A"),
      GitComparisonFile(path: "dir:foo", status: "A"),
    ])
    #expect(tree.map(\.id) == ["dir:foo", "file:dir:foo"])
    #expect(tree[1].file?.id == "dir:foo")
  }

  @Test func emptyInputProducesNoPlaceholderDirectories() {
    #expect(DiffFileTreeNode.build([]).isEmpty)
  }
}
