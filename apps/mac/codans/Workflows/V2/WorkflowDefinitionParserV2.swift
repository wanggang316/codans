import CodansIPC
import Foundation
import Yams

nonisolated enum WorkflowDefinitionParserV2 {
  static let actionOutputs: [String: Set<String>] = [
    "codans/agent.request@v1": ["result", "delivery"],
    "codans/agent.resume@v1": ["dispatch"],
    "codans/handoff.context.save@v1": ["briefing", "artifacts"],
    "codans/session.launch@v1": ["session"],
    "codans/handoff.packet.create@v1": ["packet"],
    "codans/handoff.ack.verify@v1": ["readiness"],
    "codans/human.decide@v1": ["decision", "reason"],
  ]

  static func parse(_ source: String) throws -> WorkflowDefinitionV2 {
    guard source.utf8.count <= 262_144 else { throw failure("Definition exceeds 256 KiB.") }
    var raw = try YAMLDecoder().decode([String: JSONValue].self, from: source)
    try keys(
      raw, allowed: ["schema", "id", "name", "description", "inputs", "roles", "nodes", "outputs"],
      at: "workflow")
    for field in ["inputs", "roles", "outputs"] where raw[field] == nil {
      raw[field] = .object([:])
    }
    for (id, value) in try object(raw["inputs"], at: "inputs") {
      try keys(
        object(value, at: "inputs.\(id)"), allowed: ["type", "required", "default", "description"],
        at: "inputs.\(id)")
    }
    for (id, value) in try object(raw["roles"], at: "roles") {
      try keys(
        object(value, at: "roles.\(id)"), allowed: ["label", "source", "description", "profile"],
        at: "roles.\(id)")
    }
    for (id, value) in try object(raw["nodes"], at: "nodes") {
      let node = try object(value, at: "nodes.\(id)")
      try keys(
        node, allowed: ["title", "uses", "role", "needs", "with", "expect"], at: "nodes.\(id)")
      if let expect = node["expect"] {
        try keys(
          object(expect, at: "nodes.\(id).expect"), allowed: ["format", "sections", "schema"],
          at: "nodes.\(id).expect")
      }
    }
    let definition = try JSONValue.object(raw).decoded(as: WorkflowDefinitionV2.self)
    try validate(definition)
    return definition
  }

  static func validate(_ definition: WorkflowDefinitionV2) throws {
    guard definition.schema == "codans.workflow/v1" else {
      throw failure("Unsupported workflow schema: \(definition.schema)")
    }
    guard !definition.id.isEmpty,
      !definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !definition.nodes.isEmpty
    else { throw failure("Workflow requires an id, name and at least one node.") }
    for id in Array(definition.inputs.keys) + Array(definition.roles.keys)
      + Array(definition.nodes.keys)
    {
      guard id.range(of: "^[A-Za-z_][A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
        throw failure("Invalid reference identifier: \(id)")
      }
    }
    for (id, input) in definition.inputs {
      guard ["string", "boolean", "integer", "number", "object", "array"].contains(input.type)
      else { throw failure("inputs.\(id): unsupported type") }
      if let value = input.defaultValue {
        try validateJSON(
          value, schema: .object(["type": .string(input.type)]), path: "inputs.\(id).default")
      }
    }
    try validateRoles(definition.roles)
    var completed = Set<String>()
    var ancestors: [String: Set<String>] = [:]
    for id in definition.nodeIDs {
      let node = definition.nodes[id]!
      let needs = Set(node.needs ?? [])
      guard needs.isSubset(of: completed), needs.count == (node.needs ?? []).count else {
        throw failure("nodes.\(id): dependency is missing, duplicated or cyclic")
      }
      var upstream = needs
      for parent in needs { upstream.formUnion(ancestors[parent] ?? []) }
      ancestors[id] = upstream
      try validateNode(node, id: id, definition: definition, upstream: upstream)
      try validateArguments(node, id: id, definition: definition, upstream: upstream)
      completed.insert(id)
    }
    for (id, role) in definition.roles where role.source == "launch" {
      guard
        definition.nodes.values.filter({ $0.role == id && $0.uses == "codans/session.launch@v1" })
          .count == 1
      else {
        throw failure("roles.\(id): exactly one launch node is required")
      }
    }
    for value in definition.outputs.values {
      try references(value, definition: definition, upstream: completed, path: "outputs")
    }
  }

  private static func validateRoles(_ roles: [String: WorkflowRoleV2]) throws {
    for (id, role) in roles {
      guard ["current", "pick", "launch"].contains(role.source), !role.label.isEmpty else {
        throw failure("roles.\(id): invalid source or empty label")
      }
    }
    for (id, role) in roles {
      if let profile = role.profile {
        guard role.source == "launch",
          !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          throw failure("roles.\(id).profile: a nonempty profile reference requires source: launch")
        }
      }
    }
  }

  private static func validateNode(
    _ node: WorkflowNodeV2, id: String, definition: WorkflowDefinitionV2, upstream: Set<String>
  ) throws {
    guard actionOutputs[node.uses] != nil else {
      throw failure("nodes.\(id): unknown Action \(node.uses)")
    }
    if let role = node.role, definition.roles[role] == nil {
      throw failure("nodes.\(id): unknown Role \(role)")
    }
    let agentAction = [
      "codans/session.launch@v1", "codans/agent.request@v1", "codans/agent.resume@v1",
    ].contains(
      node.uses)
    guard agentAction == (node.role != nil) else {
      throw failure("nodes.\(id): Action Role requirement is not satisfied")
    }
    if node.uses == "codans/session.launch@v1", definition.roles[node.role!]?.source != "launch" {
      throw failure("nodes.\(id): launch requires a launch Role")
    }
    if node.uses == "codans/agent.request@v1" {
      guard let expect = node.expect else {
        throw failure("nodes.\(id): agent request requires expect")
      }
      guard ["markdown", "json"].contains(expect.format) else {
        throw failure("nodes.\(id): unsupported result format")
      }
      if expect.format == "json" {
        guard let schema = expect.schema else {
          throw failure("nodes.\(id): JSON result requires a schema")
        }
        try validateSchema(schema, path: "nodes.\(id).expect.schema")
      } else if expect.schema != nil {
        throw failure("nodes.\(id): markdown cannot have a JSON schema")
      }
      if definition.roles[node.role!]?.source == "launch" {
        guard
          upstream.contains(where: {
            definition.nodes[$0]?.uses == "codans/session.launch@v1"
              && definition.nodes[$0]?.role == node.role
          })
        else {
          throw failure("nodes.\(id): launch Role must be started by an upstream node")
        }
      }
    } else if node.expect != nil {
      throw failure("nodes.\(id): expect is supported only for agent requests")
    }
    if node.uses == "codans/agent.resume@v1", definition.roles[node.role!]?.source == "launch" {
      guard
        upstream.contains(where: {
          definition.nodes[$0]?.uses == "codans/session.launch@v1"
            && definition.nodes[$0]?.role == node.role
        })
      else { throw failure("nodes.\(id): resume requires an upstream launch") }
    }
  }

  private static func actionInputs(_ action: String) -> Set<String> {
    let allowed: Set<String>
    switch action {
    case "codans/agent.request@v1": allowed = ["instruction", "context"]
    case "codans/agent.resume@v1": allowed = ["instruction", "context", "readiness"]
    case "codans/handoff.context.save@v1": allowed = ["briefing", "mode", "receiver"]
    case "codans/session.launch@v1": allowed = []
    case "codans/handoff.packet.create@v1": allowed = ["briefing"]
    case "codans/handoff.ack.verify@v1": allowed = ["packet", "acknowledgement"]
    default: allowed = ["question", "options", "evidence"]
    }
    return allowed
  }

  private static func validateArguments(
    _ node: WorkflowNodeV2, id: String, definition: WorkflowDefinitionV2, upstream: Set<String>
  ) throws {
    let allowed = actionInputs(node.uses)
    let arguments = node.arguments ?? [:]
    try keys(arguments, allowed: allowed, at: "nodes.\(id).with")
    let required: Set<String>
    switch node.uses {
    case "codans/agent.request@v1": required = ["instruction"]
    case "codans/handoff.context.save@v1": required = ["briefing", "mode"]
    default: required = allowed
    }
    guard required.isSubset(of: Set(arguments.keys)) else {
      throw failure("nodes.\(id): missing Action input")
    }
    for (name, wrapped) in arguments {
      guard case .object(let wrapper) = wrapped, let literal = wrapper["value"] else { continue }
      if ["instruction", "question", "briefing"].contains(name) {
        guard case .string(let text) = literal,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          throw failure("nodes.\(id).with.\(name): expected a nonempty string")
        }
      }
      if name == "options" {
        guard case .array(let options) = literal, !options.isEmpty,
          options.allSatisfy({
            if case .string(let text) = $0 { return !text.isEmpty }
            return false
          }),
          Set(options).count == options.count
        else {
          throw failure("nodes.\(id).with.options: expected distinct nonempty strings")
        }
      }
    }
    for value in arguments.values {
      try references(value, definition: definition, upstream: upstream, path: "nodes.\(id).with")
    }
  }

  private static func references(
    _ value: JSONValue, definition: WorkflowDefinitionV2, upstream: Set<String>, path: String
  ) throws {
    switch value {
    case .object(let fields):
      if fields["value"] != nil {
        guard fields.count == 1 else {
          throw failure("\(path): value must be the only wrapper key")
        }
      } else if let ref = fields["ref"] {
        guard fields.count == 1, case .string(let reference) = ref else {
          throw failure("\(path): invalid ref wrapper")
        }
        let parts = reference.split(separator: ".").map(String.init)
        if parts.count == 2, parts[0] == "inputs", definition.inputs[parts[1]] != nil { return }
        guard parts.count == 4, parts[0] == "nodes", parts[2] == "outputs",
          upstream.contains(parts[1]),
          let node = definition.nodes[parts[1]],
          actionOutputs[node.uses]?.contains(parts[3]) == true
        else {
          throw failure("\(path): unknown or non-upstream reference \(reference)")
        }
      } else {
        for child in fields.values {
          try references(child, definition: definition, upstream: upstream, path: path)
        }
      }
    case .array(let values):
      for child in values {
        try references(child, definition: definition, upstream: upstream, path: path)
      }
    default: throw failure("\(path): literal values require a value wrapper")
    }
  }

  static func validateResult(_ result: JSONValue, expect: WorkflowExpectationV2) throws {
    if expect.format == "json" {
      guard let schema = expect.schema else { throw failure("Missing result schema") }
      try validateJSON(result, schema: schema, path: "result")
    } else {
      guard case .string(let markdown) = result,
        !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw failure("Expected nonempty Markdown") }
      let headings = Set(
        markdown.components(separatedBy: .newlines).compactMap { line -> String? in
          let trimmed = line.trimmingCharacters(in: .whitespaces)
          guard trimmed.hasPrefix("#") else { return nil }
          return trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        })
      for section in expect.sections ?? [] where !headings.contains(section) {
        throw failure("Missing Markdown heading: \(section)")
      }
    }
  }

  private static func validateSchema(_ schema: JSONValue, path: String) throws {
    let fields = try object(schema, at: path)
    try keys(
      fields,
      allowed: ["type", "required", "additionalProperties", "properties", "items", "minLength"],
      at: path)
    guard case .string(let type) = fields["type"],
      ["object", "array", "string", "integer", "number", "boolean", "null"].contains(type)
    else { throw failure("\(path): unsupported schema type") }
    if let properties = fields["properties"] {
      for (key, child) in try object(properties, at: path) {
        try validateSchema(child, path: "\(path).\(key)")
      }
    }
    if let items = fields["items"] { try validateSchema(items, path: "\(path).items") }
    if let required = fields["required"] {
      guard case .array(let names) = required,
        names.allSatisfy({
          if case .string = $0 { return true }
          return false
        })
      else { throw failure("\(path): required must contain field names") }
    }
    if let additional = fields["additionalProperties"], case .bool = additional {
    } else if fields["additionalProperties"] != nil {
      throw failure("\(path): additionalProperties must be boolean")
    }
    if let minimum = fields["minLength"] {
      guard case .int(let length) = minimum, length >= 0 else {
        throw failure("\(path): minLength must be nonnegative")
      }
    }
  }

  static func validateJSON(_ value: JSONValue, schema: JSONValue, path: String) throws {
    let fields = try object(schema, at: path)
    guard case .string(let type) = fields["type"] else {
      throw failure("\(path): missing schema type")
    }
    let matches: Bool
    switch (type, value) {
    case ("string", .string), ("object", .object), ("array", .array), ("integer", .int),
      ("number", .int), ("number", .double), ("boolean", .bool), ("null", .null):
      matches = true
    default: matches = false
    }
    guard matches else { throw failure("\(path): expected \(type)") }
    if case .string(let text) = value, case .int(let minimum) = fields["minLength"],
      text.count < minimum
    {
      throw failure("\(path): string is too short")
    }
    if case .array(let values) = value, let items = fields["items"] {
      for (index, child) in values.enumerated() {
        try validateJSON(child, schema: items, path: "\(path)[\(index)]")
      }
    }
    if case .object(let values) = value {
      let properties = try object(fields["properties"] ?? .object([:]), at: path)
      if case .array(let required) = fields["required"] {
        for case .string(let name) in required where values[name] == nil {
          throw failure("\(path): missing \(name)")
        }
      }
      if fields["additionalProperties"] == .bool(false) {
        try keys(values, allowed: Set(properties.keys), at: path)
      }
      for (name, child) in values {
        if let childSchema = properties[name] {
          try validateJSON(child, schema: childSchema, path: "\(path).\(name)")
        }
      }
    }
  }

  private static func object(_ value: JSONValue?, at path: String) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else { throw failure("\(path): expected a mapping") }
    return fields
  }

  private static func keys(_ fields: [String: JSONValue], allowed: Set<String>, at path: String)
    throws
  {
    let unknown = Set(fields.keys).subtracting(allowed).sorted()
    guard unknown.isEmpty else {
      throw failure("\(path): unsupported fields \(unknown.joined(separator: ", "))")
    }
  }

  private static func failure(_ message: String) -> WorkflowDefinitionErrorV2 {
    WorkflowDefinitionErrorV2(message: message)
  }
}
