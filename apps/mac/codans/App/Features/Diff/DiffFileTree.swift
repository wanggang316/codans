import CodansCore
import Foundation

nonisolated struct DiffFileTreeNode: Identifiable, Equatable {
  var id: String
  var name: String
  var path: String
  var file: GitComparisonFile?
  var children: [DiffFileTreeNode]?

  static func build(_ files: [GitComparisonFile]) -> [DiffFileTreeNode] {
    build(files.map { Entry(file: $0, components: $0.path.components(separatedBy: "/")) }, depth: 0)
  }

  private struct Entry {
    var file: GitComparisonFile
    var components: [String]
  }

  private static func build(_ entries: [Entry], depth: Int) -> [DiffFileTreeNode] {
    var nodes: [DiffFileTreeNode] = []
    var directories: [String: [Entry]] = [:]
    for entry in entries {
      let name = entry.components[depth]
      if depth == entry.components.count - 1 {
        nodes.append(
          Self(id: "file:\(entry.file.id)", name: name, path: entry.file.path, file: entry.file, children: nil))
      } else {
        directories[name, default: []].append(entry)
      }
    }
    for (name, descendants) in directories {
      guard let first = descendants.first else { continue }
      let path = first.components.prefix(depth + 1).joined(separator: "/")
      nodes.append(
        Self(
          id: "dir:\(path)", name: name, path: path, file: nil,
          children: build(descendants, depth: depth + 1)))
    }
    return nodes.sorted { lhs, rhs in
      if (lhs.children != nil) != (rhs.children != nil) { return lhs.children != nil }
      let order = lhs.name.localizedStandardCompare(rhs.name)
      return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
    }
  }
}
