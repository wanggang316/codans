import CodansIPC
import Foundation

nonisolated struct WorkflowDefinitionV2: Codable, Equatable, Sendable {
  var schema: String
  var id: String
  var name: String
  var description: String?
  var inputs: [String: WorkflowInputV2]
  var roles: [String: WorkflowRoleV2]
  var nodes: [String: WorkflowNodeV2]
  var outputs: [String: JSONValue]

  var nodeIDs: [String] {
    var remaining = Set(nodes.keys)
    var ordered: [String] = []
    while !remaining.isEmpty {
      let ready = remaining.filter { Set(nodes[$0]?.needs ?? []).isSubset(of: Set(ordered)) }
        .sorted()
      guard !ready.isEmpty else { return ordered + remaining.sorted() }
      ordered.append(contentsOf: ready)
      remaining.subtract(ready)
    }
    return ordered
  }
}

nonisolated struct WorkflowInputV2: Codable, Equatable, Sendable {
  var type: String
  var required: Bool?
  var defaultValue: JSONValue?
  var description: String?
  enum CodingKeys: String, CodingKey {
    case type, required, description
    case defaultValue = "default"
  }
}

nonisolated struct WorkflowRoleV2: Codable, Equatable, Sendable {
  var label: String
  var source: String
  var description: String?
  var profile: String?
}

nonisolated struct WorkflowNodeV2: Codable, Equatable, Sendable {
  var title: String?
  var uses: String
  var role: String?
  var needs: [String]?
  var arguments: [String: JSONValue]?
  var expect: WorkflowExpectationV2?
  enum CodingKeys: String, CodingKey {
    case title, uses, role, needs, expect
    case arguments = "with"
  }
}

nonisolated struct WorkflowExpectationV2: Codable, Equatable, Sendable {
  var format: String
  var sections: [String]?
  var schema: JSONValue?
}

nonisolated struct WorkflowDefinitionErrorV2: LocalizedError {
  var message: String
  var errorDescription: String? { message }
}
