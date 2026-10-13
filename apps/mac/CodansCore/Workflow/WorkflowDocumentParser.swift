import Foundation
import Yams

/// YAML text → `WorkflowDefinition`, plus every structural finding on the way:
/// unknown keys, wrong shapes, missing required keys, a step with zero or
/// several verbs, malformed expressions and templates. Cross references
/// (roles that exist, deliveries that are produced) are `WorkflowValidator`'s
/// job and run only once this parser hands back a definition.
///
/// Parsing keeps going after an error wherever the rest of the document is
/// still meaningful, so an author sees every mistake in one pass rather than
/// one per save. The definition is withheld whenever any error was recorded:
/// a partially understood file must never reach the run machine.
public nonisolated enum WorkflowDocumentParser {
  public static let fileSuffix = ".workflow.yaml"

  /// `review-loop.workflow.yaml` → `review-loop`; `nil` when the suffix is
  /// missing or the stem is not a valid identifier.
  public static func workflowID(fromFileName fileName: String) -> String? {
    guard fileName.hasSuffix(fileSuffix) else { return nil }
    let stem = String(fileName.dropLast(fileSuffix.count))
    return WorkflowDefinition.isValidIdentifier(stem) ? stem : nil
  }

  public static func parse(
    yaml: String, id: String
  ) -> (definition: WorkflowDefinition?, diagnostics: [WorkflowDiagnostic]) {
    var session = Session()
    let definition = session.parseDocument(yaml, id: id)
    return (session.diagnostics.hasErrors ? nil : definition, session.diagnostics)
  }
}

// MARK: - Session

extension WorkflowDocumentParser {
  /// A YAML node together with the dotted path a diagnostic would cite.
  private struct Field {
    let node: Node
    let path: String

    /// `nil` at the document root, where there is nothing to point at.
    var location: String? { path.isEmpty ? nil : path }

    func child(_ key: String) -> String {
      path.isEmpty ? key : "\(path).\(key)"
    }

    func child(index: Int) -> String {
      "\(path)[\(index)]"
    }
  }

  private struct Entry {
    let key: String
    let field: Field
  }

  /// What a YAML scalar means under the core schema. Quoted `"5"` is a
  /// string and plain `5` is an integer, which is exactly the distinction
  /// `state:` literals and typed input defaults need.
  private enum Scalar {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    /// Floats, timestamps, and anything else the workflow language has no
    /// value for. The payload is the raw text for messages.
    case unsupported(String)
  }

  private struct Session {
    var diagnostics: [WorkflowDiagnostic] = []
    /// Position in flattened document order; the source of `step-<n>`.
    private var nextStepNumber = 1
    private var seenStepIDs: Set<String> = []

    static let verbKeys = ["message", "launch", "run", "wait", "notify", "close", "set", "while", "break", "continue"]
    static let payloadKeys: [String: [String]] = [
      "message": ["text", "instruction", "expect"],
      "launch": ["prompt", "expect"],
      "run": ["working-directory", "env", "timeout-minutes", "continue-on-error", "in"],
      "wait": ["until", "timeout-minutes"],
      "notify": [],
      "close": [],
      "set": [],
      "while": ["steps", "max-iterations"],
      "break": [],
      "continue": [],
    ]

    // MARK: Document

    mutating func parseDocument(_ yaml: String, id: String) -> WorkflowDefinition? {
      let root: Node?
      do {
        root = try Yams.compose(yaml: yaml)
      } catch {
        report(.error("invalid_yaml", "\(error)"))
        return nil
      }
      guard let root else {
        report(.error("empty_document", "the file contains no YAML document"))
        return nil
      }
      let document = Field(node: root, path: "")
      guard let fields = fields(of: document, allowed: ["name", "description", "inputs", "roles", "state", "steps"])
      else { return nil }

      let name = fields["name"].flatMap { string($0) }
      if fields["name"] == nil {
        report(.error("missing_key", "`name` is required", at: "name"))
      }
      let description = fields["description"].flatMap { string($0) }
      let inputs = fields["inputs"].map { parseInputs($0) } ?? []
      let roles = fields["roles"].map { parseRoles($0) } ?? []
      let state = fields["state"].map { parseState($0) } ?? []
      let steps: [WorkflowStep]
      if let stepsField = fields["steps"] {
        steps = parseSteps(stepsField)
      } else {
        report(.error("missing_key", "`steps` is required", at: "steps"))
        steps = []
      }
      return WorkflowDefinition(
        id: id, name: name ?? "", description: description, inputs: inputs, roles: roles, state: state, steps: steps)
    }

    // MARK: Inputs

    private mutating func parseInputs(_ field: Field) -> [WorkflowInput] {
      guard let entries = entries(of: field) else { return [] }
      return entries.compactMap { parseInput($0) }
    }

    private mutating func parseInput(_ entry: Entry) -> WorkflowInput? {
      let name = identifier(entry.key, at: entry.field.path)
      let allowed = ["description", "type", "required", "default", "options", "min", "max"]
      guard let fields = fields(of: entry.field, allowed: allowed) else { return nil }
      var kind = WorkflowInput.Kind.string
      if let kindField = fields["type"] {
        // An unknown `type` was already reported; typing the rest against
        // the `string` fallback would only add noise.
        guard let parsedKind = enumeration(kindField, as: WorkflowInput.Kind.self) else { return nil }
        kind = parsedKind
      }
      let options = fields["options"].flatMap { stringList($0) } ?? []
      if fields["options"] != nil, kind != .choice {
        report(.error("key_not_allowed", "`options` only applies to `type: choice`", at: entry.field.child("options")))
      }
      for key in ["min", "max"] where fields[key] != nil && kind != .number {
        report(.error("key_not_allowed", "`\(key)` only applies to `type: number`", at: entry.field.child(key)))
      }
      if kind == .choice, fields["options"] == nil {
        report(.error("missing_key", "`type: choice` needs `options`", at: entry.field.child("options")))
      } else if kind == .choice, options.isEmpty, fields["options"] != nil {
        report(.error("empty_collection", "`options` must list at least one choice", at: entry.field.child("options")))
      }
      var input = WorkflowInput(
        name: name ?? entry.key,
        description: fields["description"].flatMap { string($0) },
        kind: kind,
        required: fields["required"].flatMap { bool($0) } ?? false,
        options: options,
        min: fields["min"].flatMap { int($0) },
        max: fields["max"].flatMap { int($0) })
      if let defaultField = fields["default"] {
        input.defaultValue = parseInputDefault(defaultField, for: input)
      }
      return name == nil ? nil : input
    }

    private mutating func parseInputDefault(_ field: Field, for input: WorkflowInput) -> WorkflowValue? {
      guard let scalar = scalar(field) else { return nil }
      if case .null = scalar { return nil }
      switch input.kind {
      case .number:
        guard case .int(let value) = scalar else {
          report(.error("invalid_default", "a `number` default must be an integer", at: field.path))
          return nil
        }
        if let min = input.min, value < min {
          report(.error("invalid_default", "default \(value) is below `min` \(min)", at: field.path))
        }
        if let max = input.max, value > max {
          report(.error("invalid_default", "default \(value) is above `max` \(max)", at: field.path))
        }
        return .int(value)
      case .boolean:
        guard case .bool(let value) = scalar else {
          report(.error("invalid_default", "a `boolean` default must be `true` or `false`", at: field.path))
          return nil
        }
        return .bool(value)
      case .string:
        let text = field.node.scalar?.string ?? ""
        guard isSingleLine(text) else {
          report(
            .error(
              "invalid_default", "a `string` default must be a single line without control characters", at: field.path))
          return nil
        }
        return .string(text)
      case .choice:
        let text = field.node.scalar?.string ?? ""
        guard input.options.contains(text) else {
          report(.error("invalid_default", "default \"\(text)\" is not one of `options`", at: field.path))
          return nil
        }
        return .string(text)
      }
    }

    // MARK: Roles

    private mutating func parseRoles(_ field: Field) -> [WorkflowRole] {
      guard let entries = entries(of: field) else { return [] }
      return entries.compactMap { parseRole($0) }
    }

    private mutating func parseRole(_ entry: Entry) -> WorkflowRole? {
      let name = identifier(entry.key, at: entry.field.path)
      let launchOnly = ["agents", "profile", "placement", "direction", "background"]
      guard let fields = fields(of: entry.field, allowed: ["source"] + launchOnly) else { return nil }
      guard let sourceField = fields["source"] else {
        report(.error("missing_key", "`source` is required (current | launch | pick)", at: entry.field.child("source")))
        return nil
      }
      guard let source = enumeration(sourceField, as: WorkflowRole.Source.self) else { return nil }
      if source != .launch {
        for key in launchOnly where fields[key] != nil {
          report(.error("key_not_allowed", "`\(key)` only applies to `source: launch`", at: entry.field.child(key)))
        }
      }
      guard let name else { return nil }
      return WorkflowRole(
        name: name,
        source: source,
        agents: fields["agents"].flatMap { parseAgents($0) },
        profile: fields["profile"].flatMap { string($0) },
        placement: fields["placement"].flatMap { enumeration($0, as: WorkflowRole.Placement.self) } ?? .split,
        direction: fields["direction"].flatMap { enumeration($0, as: ScriptSplitDirection.self) } ?? .right,
        background: fields["background"].flatMap { bool($0) } ?? false)
    }

    /// Unknown agent tokens are dropped with a warning rather than failing
    /// the file: a workflow written against a newer app should still run
    /// here with the agents this build knows.
    private mutating func parseAgents(_ field: Field) -> [AgentKind]? {
      guard let items = sequence(field) else { return nil }
      var kinds: [AgentKind] = []
      for item in items {
        guard let token = string(item) else { continue }
        if let kind = AgentKind(rawValue: token) {
          kinds.append(kind)
        } else {
          report(.warning("unknown_agent", "unknown agent `\(token)` is ignored", at: item.path))
        }
      }
      return kinds
    }

    // MARK: State

    private mutating func parseState(_ field: Field) -> [WorkflowStateVariable] {
      guard let entries = entries(of: field) else { return [] }
      return entries.compactMap { entry in
        let name = identifier(entry.key, at: entry.field.path)
        guard let scalar = scalar(entry.field) else { return nil }
        let initial: WorkflowValue
        switch scalar {
        case .int(let value): initial = .int(value)
        case .bool(let value): initial = .bool(value)
        case .string(let value): initial = .string(value)
        case .null, .unsupported:
          report(
            .error(
              "invalid_value", "a state variable's initial value must be an integer, boolean, or string",
              at: entry.field.path))
          return nil
        }
        guard let name else { return nil }
        return WorkflowStateVariable(name: name, initial: initial)
      }
    }

    // MARK: Steps

    private mutating func parseSteps(_ field: Field) -> [WorkflowStep] {
      guard let items = sequence(field) else { return [] }
      if items.isEmpty {
        report(.error("empty_collection", "`steps` must contain at least one step", at: field.path))
      }
      return items.compactMap { parseStep($0) }
    }

    private mutating func parseStep(_ field: Field) -> WorkflowStep? {
      guard let entries = entries(of: field) else { return nil }
      // Numbered before the body is parsed so a loop precedes its steps.
      let number = nextStepNumber
      nextStepNumber += 1

      let verbs = entries.map(\.key).filter { Self.verbKeys.contains($0) }
      guard verbs.count == 1, let verb = verbs.first else {
        if verbs.isEmpty {
          report(
            .error(
              "verb_required", "a step needs exactly one of: \(Self.verbKeys.joined(separator: ", "))", at: field.path))
        } else {
          report(
            .error("multiple_verbs", "a step has one verb, found: \(verbs.joined(separator: ", "))", at: field.path))
        }
        return nil
      }
      let allowed = ["name", "id", "if", verb] + (Self.payloadKeys[verb] ?? [])
      let fields = fields(from: entries, allowed: allowed)

      let explicitID = fields["id"].flatMap { identifierField($0) }
      if let explicitID {
        if !seenStepIDs.insert(explicitID).inserted {
          report(.error("duplicate_step_id", "step id `\(explicitID)` is used more than once", at: field.child("id")))
        }
      }
      let id = explicitID ?? "step-\(number)"
      let name = fields["name"].flatMap { string($0) }
      let condition = fields["if"].flatMap { expression($0) }
      guard let parsed = parseVerb(verb, fields: fields, step: field, stepID: id) else { return nil }
      return WorkflowStep(
        id: id, hasExplicitID: explicitID != nil, name: name, condition: condition, verb: parsed, path: field.path)
    }

    private mutating func parseVerb(
      _ verb: String, fields: [String: Field], step: Field, stepID: String
    ) -> WorkflowStepVerb? {
      guard let payload = fields[verb] else { return nil }
      switch verb {
      case "message": return parseMessage(payload, fields: fields, step: step, stepID: stepID)
      case "launch": return parseLaunch(payload, fields: fields, step: step, stepID: stepID)
      case "run": return parseRun(payload, fields: fields, step: step)
      case "wait": return parseWait(payload, fields: fields)
      case "notify": return template(payload).map { WorkflowStepVerb.notify($0) }
      case "close": return identifierField(payload).map { WorkflowStepVerb.close(role: $0) }
      case "set": return parseSet(payload)
      case "while": return parseLoop(payload, fields: fields, step: step)
      case "break": return literalTrue(payload) ? .breakLoop : nil
      case "continue": return literalTrue(payload) ? .continueLoop : nil
      default: return nil
      }
    }

    private mutating func parseMessage(
      _ payload: Field, fields: [String: Field], step: Field, stepID: String
    ) -> WorkflowStepVerb? {
      let role = identifierField(payload)
      let expect = fields["expect"].flatMap { parseExpectation($0, stepID: stepID) }
      let content: WorkflowMessageContent?
      switch (fields["text"], fields["instruction"]) {
      case (let text?, nil):
        content = template(text).flatMap { template in
          guard isSingleLine(template.source) else {
            report(.error("multiline_text", "`text` must be a single line; use `instruction` for more", at: text.path))
            return nil
          }
          return .text(template)
        }
      case (nil, let instruction?):
        content = template(instruction).map { .instruction($0) }
      case (nil, nil):
        report(.error("content_required", "`message` needs `text` or `instruction`", at: step.path))
        content = nil
      case (.some, .some):
        report(.error("multiple_contents", "`message` takes either `text` or `instruction`, not both", at: step.path))
        content = nil
      }
      guard let role, let content else { return nil }
      return .message(role: role, content: content, expect: expect)
    }

    private mutating func parseLaunch(
      _ payload: Field, fields: [String: Field], step: Field, stepID: String
    ) -> WorkflowStepVerb? {
      let role = identifierField(payload)
      let expect = fields["expect"].flatMap { parseExpectation($0, stepID: stepID) }
      guard let promptField = fields["prompt"] else {
        report(.error("missing_key", "`launch` needs a `prompt`", at: step.child("prompt")))
        return nil
      }
      guard let role, let prompt = template(promptField) else { return nil }
      return .launch(role: role, prompt: prompt, expect: expect)
    }

    private mutating func parseRun(_ payload: Field, fields: [String: Field], step: Field) -> WorkflowStepVerb? {
      let command = template(payload)
      let workingDirectory = fields["working-directory"].flatMap { template($0) }
      let env = fields["env"].flatMap { parseEnvironment($0) } ?? [:]
      let timeout = fields["timeout-minutes"].flatMap { int($0, atLeast: 1) }
      let continueOnError = fields["continue-on-error"].flatMap { bool($0) } ?? false
      let inRole = fields["in"].flatMap { identifierField($0) }
      guard let command else { return nil }
      return .run(
        WorkflowRunCommand(
          command: command,
          workingDirectory: workingDirectory,
          env: env,
          timeoutMinutes: timeout ?? WorkflowRunCommand.defaultTimeoutMinutes,
          continueOnError: continueOnError,
          inRole: inRole))
    }

    private mutating func parseEnvironment(_ field: Field) -> [String: WorkflowTemplate]? {
      guard let entries = entries(of: field) else { return nil }
      var env: [String: WorkflowTemplate] = [:]
      for entry in entries {
        if let value = template(entry.field) { env[entry.key] = value }
      }
      return env
    }

    private mutating func parseWait(_ payload: Field, fields: [String: Field]) -> WorkflowStepVerb? {
      let role = identifierField(payload)
      let until = fields["until"].flatMap { enumeration($0, as: WorkflowWaitCondition.self) } ?? .idle
      let timeout = fields["timeout-minutes"].flatMap { int($0, atLeast: 1) }
      guard let role else { return nil }
      return .wait(role: role, until: until, timeoutMinutes: timeout)
    }

    private mutating func parseSet(_ payload: Field) -> WorkflowStepVerb? {
      guard let entries = entries(of: payload) else { return nil }
      if entries.isEmpty {
        report(.error("empty_collection", "`set` must assign at least one variable", at: payload.path))
        return nil
      }
      let assignments = entries.compactMap { entry -> WorkflowAssignment? in
        let name = identifier(entry.key, at: entry.field.path)
        guard let name, let value = template(entry.field) else { return nil }
        return WorkflowAssignment(name: name, value: value)
      }
      return assignments.count == entries.count ? .set(assignments) : nil
    }

    private mutating func parseLoop(_ payload: Field, fields: [String: Field], step: Field) -> WorkflowStepVerb? {
      let condition = expression(payload)
      let maxIterations = fields["max-iterations"].flatMap { int($0, atLeast: 1) }
      guard let stepsField = fields["steps"] else {
        report(.error("missing_key", "`while` needs a `steps` body", at: step.child("steps")))
        return nil
      }
      let body = parseSteps(stepsField)
      guard let condition else { return nil }
      return .loop(condition: condition, maxIterations: maxIterations, steps: body)
    }

    private mutating func literalTrue(_ field: Field) -> Bool {
      guard let value = bool(field) else { return false }
      guard value else {
        report(.error("invalid_value", "expected `true`", at: field.path))
        return false
      }
      return true
    }

    // MARK: Expectation

    private mutating func parseExpectation(_ field: Field, stepID: String) -> WorkflowExpectation? {
      let allowed = ["delivery", "format", "sections", "verdicts", "timeout-minutes", "on-timeout", "strict"]
      guard let fields = fields(of: field, allowed: allowed) else { return nil }
      let delivery = fields["delivery"].flatMap { identifierField($0) } ?? stepID
      let format = fields["format"].flatMap { enumeration($0, as: WorkflowExpectation.Format.self) } ?? .markdown
      let sections = fields["sections"].flatMap { stringList($0) } ?? []
      let verdicts = fields["verdicts"].flatMap { parseVerdicts($0) }
      let timeout = fields["timeout-minutes"].flatMap { int($0, atLeast: 1) }
      let onTimeout = fields["on-timeout"].flatMap { enumeration($0, as: WorkflowExpectation.TimeoutPolicy.self) }
      if fields["on-timeout"] != nil, fields["timeout-minutes"] == nil {
        report(
          .error(
            "on_timeout_without_timeout", "`on-timeout` has no effect without `timeout-minutes`",
            at: field.child("on-timeout")))
      }
      let strict = fields["strict"].flatMap { bool($0) } ?? false
      return WorkflowExpectation(
        delivery: delivery, format: format, sections: sections, verdicts: verdicts, timeoutMinutes: timeout,
        onTimeout: onTimeout ?? .attention, strict: strict)
    }

    private mutating func parseVerdicts(_ field: Field) -> [String]? {
      guard let items = sequence(field) else { return nil }
      let range = WorkflowExpectation.minimumVerdicts...WorkflowExpectation.maximumVerdicts
      if !range.contains(items.count) {
        report(
          .error(
            "verdict_count",
            "`verdicts` needs \(range.lowerBound) to \(range.upperBound) entries, found \(items.count)",
            at: field.path))
      }
      let verdicts = items.compactMap { identifierField($0) }
      return verdicts.count == items.count ? verdicts : nil
    }

    // MARK: Node readers

    private mutating func report(_ diagnostic: WorkflowDiagnostic) {
      diagnostics.append(diagnostic)
    }

    /// The mapping's pairs in document order. Keys must be scalars; a
    /// repeated key is already a `YamlError` at compose time.
    private mutating func entries(of field: Field) -> [Entry]? {
      guard case .mapping(let mapping) = field.node else {
        report(.error("invalid_type", "expected a mapping", at: field.location))
        return nil
      }
      var entries: [Entry] = []
      for (key, value) in mapping {
        guard let name = key.scalar?.string else {
          report(.error("invalid_key", "keys must be plain strings", at: field.location))
          continue
        }
        entries.append(Entry(key: name, field: Field(node: value, path: field.child(name))))
      }
      return entries
    }

    /// Mapping with a fixed vocabulary: anything outside `allowed` is an
    /// `unknown_key`, the usual symptom of a typo or a stale spelling.
    private mutating func fields(of field: Field, allowed: [String]) -> [String: Field]? {
      guard let entries = entries(of: field) else { return nil }
      return fields(from: entries, allowed: allowed)
    }

    private mutating func fields(from entries: [Entry], allowed: [String]) -> [String: Field] {
      var fields: [String: Field] = [:]
      for entry in entries {
        guard allowed.contains(entry.key) else {
          report(.error("unknown_key", "unknown key `\(entry.key)`", at: entry.field.path))
          continue
        }
        fields[entry.key] = entry.field
      }
      return fields
    }

    private mutating func sequence(_ field: Field) -> [Field]? {
      guard case .sequence(let sequence) = field.node else {
        report(.error("invalid_type", "expected a list", at: field.location))
        return nil
      }
      return sequence.enumerated().map { Field(node: $0.element, path: field.child(index: $0.offset)) }
    }

    private mutating func scalar(_ field: Field) -> Scalar? {
      guard case .scalar(let scalar) = field.node else {
        report(.error("invalid_type", "expected a scalar value", at: field.location))
        return nil
      }
      // `Node.tag` is the resolved core-schema tag; only its raw form is public.
      switch Yams.Tag.Name(rawValue: field.node.tag.rawValue) {
      case .null: return .null
      case .bool: return field.node.bool.map { .bool($0) } ?? .string(scalar.string)
      case .int: return field.node.int.map { .int($0) } ?? .unsupported(scalar.string)
      case .str: return .string(scalar.string)
      default: return .unsupported(scalar.string)
      }
    }

    /// Any non-null scalar read as the text the author wrote: `name: 42` is
    /// "42" and `verdicts: [yes, no]` keeps `yes` / `no` even though the core
    /// schema would resolve them as booleans.
    private mutating func string(_ field: Field) -> String? {
      guard let scalar = scalar(field), let raw = field.node.scalar?.string else { return nil }
      if case .null = scalar {
        report(.error("invalid_type", "expected a string", at: field.path))
        return nil
      }
      return raw
    }

    private mutating func bool(_ field: Field) -> Bool? {
      guard let scalar = scalar(field) else { return nil }
      guard case .bool(let value) = scalar else {
        report(.error("invalid_type", "expected `true` or `false`", at: field.path))
        return nil
      }
      return value
    }

    private mutating func int(_ field: Field, atLeast minimum: Int? = nil) -> Int? {
      guard let scalar = scalar(field) else { return nil }
      guard case .int(let value) = scalar else {
        report(.error("invalid_type", "expected an integer", at: field.path))
        return nil
      }
      if let minimum, value < minimum {
        report(.error("invalid_value", "expected an integer of at least \(minimum)", at: field.path))
        return nil
      }
      return value
    }

    private mutating func identifier(_ candidate: String, at path: String) -> String? {
      guard WorkflowDefinition.isValidIdentifier(candidate) else {
        report(
          .error(
            "invalid_identifier", "`\(candidate)` must match [a-z0-9][a-z0-9_.-]{0,63}", at: path))
        return nil
      }
      return candidate
    }

    private mutating func identifierField(_ field: Field) -> String? {
      guard let text = string(field) else { return nil }
      return identifier(text, at: field.path)
    }

    private mutating func stringList(_ field: Field) -> [String]? {
      guard let items = sequence(field) else { return nil }
      let strings = items.compactMap { string($0) }
      return strings.count == items.count ? strings : nil
    }

    private mutating func enumeration<Value: RawRepresentable & CaseIterable>(
      _ field: Field, as type: Value.Type
    ) -> Value? where Value.RawValue == String {
      guard let text = string(field) else { return nil }
      guard let value = Value(rawValue: text) else {
        let options = Value.allCases.map(\.rawValue).joined(separator: " | ")
        report(.error("invalid_value", "expected one of \(options), found `\(text)`", at: field.path))
        return nil
      }
      return value
    }

    private mutating func template(_ field: Field) -> WorkflowTemplate? {
      guard let text = string(field) else { return nil }
      do {
        return try WorkflowTemplate.parse(text)
      } catch {
        report(.error("invalid_template", error.message, at: field.path))
        return nil
      }
    }

    private mutating func expression(_ field: Field) -> WorkflowExpression? {
      guard let text = string(field) else { return nil }
      do {
        return try WorkflowExpression.parse(text)
      } catch {
        report(.error("invalid_expression", error.message, at: field.path))
        return nil
      }
    }

    private func isSingleLine(_ text: String) -> Bool {
      !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
  }
}
