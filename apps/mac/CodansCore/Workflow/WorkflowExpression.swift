import Foundation

/// The workflow expression language: the part of a definition that is
/// evaluated at run time inside `${{ … }}`, or bare in `if:` / `while:`.
///
/// Deliberately small — literals, dotted references, comparison, boolean
/// logic, `??`, integer `+`/`-`, and five functions. Spelling follows GitHub
/// Actions where the two overlap so authors carry nothing new: single-quoted
/// strings with `''` escapes, `contains` / `startsWith` / `endsWith`, `&&`
/// / `||` / `!`. Missing references are errors; `exists()` and `??` are the
/// only ways to tolerate absence, which is what lets the validator and the
/// skip-consequence analysis read `references` and trust them.
///
/// Identifiers may contain `-` (`inputs.max-rounds`, `steps.run-tests`), so
/// binary minus must be surrounded by whitespace: `a - b` subtracts, `a-b`
/// is one name.
public nonisolated struct WorkflowExpression: Equatable, Sendable, Hashable {
  public let source: String
  let node: Node

  /// Parses a bare expression. `${{ … }}` wrapping is accepted and stripped
  /// so `if: ${{ x }}` and `if: x` mean the same thing.
  public static func parse(_ source: String) throws(WorkflowExpressionError) -> WorkflowExpression {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    var body = Substring(trimmed)
    if body.hasPrefix("${{"), body.hasSuffix("}}") {
      body = body.dropFirst(3).dropLast(2)
    }
    var parser = Parser(tokens: try Lexer.tokenize(String(body)))
    let node = try parser.parseExpression()
    guard parser.atEnd else {
      throw .syntax("unexpected token \(parser.currentDescription)", offset: parser.currentOffset)
    }
    return WorkflowExpression(source: source, node: node)
  }

  init(source: String, node: Node) {
    self.source = source
    self.node = node
  }

  public func evaluate(in context: WorkflowContext) throws(WorkflowExpressionError) -> WorkflowValue {
    try Evaluator(context: context).evaluate(node)
  }

  /// Evaluates and requires a boolean, the contract for `if:` / `while:`.
  public func evaluateCondition(in context: WorkflowContext) throws(WorkflowExpressionError) -> Bool {
    let value = try evaluate(in: context)
    guard let flag = value.boolValue else {
      throw .typeMismatch("condition must be a boolean, got \(value.typeName)")
    }
    return flag
  }

  /// References that must resolve for evaluation to succeed: every dotted
  /// path except those guarded by `exists()` or sitting on the right of
  /// `??`. Order is first appearance.
  public var references: [WorkflowReference] {
    var found: [WorkflowReference] = []
    Self.collectReferences(node, required: true, into: &found)
    return found
  }

  /// Every reference, guarded or not. Used to report names the workflow
  /// could never produce.
  public var allReferences: [WorkflowReference] {
    var found: [WorkflowReference] = []
    Self.collectReferences(node, required: false, into: &found)
    return found
  }

  private static func collectReferences(_ node: Node, required: Bool, into found: inout [WorkflowReference]) {
    switch node {
    case .literal:
      break
    case .reference(let path):
      let reference = WorkflowReference(path: path)
      if !found.contains(reference) { found.append(reference) }
    case .index(let base, let key):
      // `a.b['c']` is a static path when the key is a literal.
      if let flattened = flattenedPath(node) {
        let reference = WorkflowReference(path: flattened)
        if !found.contains(reference) { found.append(reference) }
      } else {
        collectReferences(base, required: required, into: &found)
        collectReferences(key, required: required, into: &found)
      }
    case .unary(_, let operand):
      collectReferences(operand, required: required, into: &found)
    case .binary(let op, let lhs, let rhs):
      if op == .coalesce, required {
        // `a ?? b` tolerates `a` being absent by design, and `b` is only
        // read when it is — neither side is required.
        return
      }
      collectReferences(lhs, required: required, into: &found)
      collectReferences(rhs, required: required, into: &found)
    case .call(let name, let arguments):
      if name == "exists", required { return }
      for argument in arguments {
        collectReferences(argument, required: required, into: &found)
      }
    }
  }

  private static func flattenedPath(_ node: Node) -> [String]? {
    switch node {
    case .reference(let path):
      return path
    case .index(let base, .literal(.string(let key))):
      guard let prefix = flattenedPath(base) else { return nil }
      return prefix + [key]
    default:
      return nil
    }
  }

  // MARK: - AST

  indirect enum Node: Equatable, Sendable, Hashable {
    case literal(WorkflowValue)
    case reference([String])
    case index(Node, Node)
    case unary(UnaryOperator, Node)
    case binary(BinaryOperator, Node, Node)
    case call(String, [Node])
  }

  enum UnaryOperator: Equatable, Sendable, Hashable {
    case not
    case negate
  }

  enum BinaryOperator: Equatable, Sendable, Hashable {
    case add
    case subtract
    case less
    case lessOrEqual
    case greater
    case greaterOrEqual
    case equal
    case notEqual
    case and
    case or
    case coalesce
  }
}

/// A dotted path an expression dereferences (`deliveries.review.path`).
public nonisolated struct WorkflowReference: Equatable, Sendable, Hashable, CustomStringConvertible {
  public let path: [String]

  public init(path: [String]) {
    self.path = path
  }

  public var namespace: String { path.first ?? "" }
  public var description: String { path.joined(separator: ".") }
}

public nonisolated enum WorkflowExpressionError: Error, Equatable, Sendable {
  case syntax(String, offset: Int)
  case missingReference(WorkflowReference)
  case typeMismatch(String)
  case unknownFunction(String)
  case arity(function: String, expected: Int)
  case overflow

  public var message: String {
    switch self {
    case .syntax(let detail, let offset): return "syntax error at offset \(offset): \(detail)"
    case .missingReference(let reference): return "`\(reference)` is not defined"
    case .typeMismatch(let detail): return detail
    case .unknownFunction(let name): return "unknown function `\(name)`"
    case .arity(let function, let expected): return "`\(function)` takes \(expected) argument(s)"
    case .overflow: return "integer overflow"
    }
  }
}

// MARK: - Context

/// The read-only namespaces an expression sees, as one object value:
/// `inputs`, `state`, `steps`, `deliveries`, `roles`, `workflow`, `run`,
/// `worktree`, `loop`, `codans`. Built by the run machine per step.
public nonisolated struct WorkflowContext: Equatable, Sendable {
  public var root: [String: WorkflowValue]

  public init(_ root: [String: WorkflowValue] = [:]) {
    self.root = root
  }

  /// Walks `path` through nested objects. `nil` when any segment is absent
  /// or the value on the way is not an object.
  public func value(at path: [String]) -> WorkflowValue? {
    guard let first = path.first, var current = root[first] else { return nil }
    for key in path.dropFirst() {
      guard let next = current[key] else { return nil }
      current = next
    }
    return current
  }

  public subscript(namespace: String) -> WorkflowValue? {
    get { root[namespace] }
    set { root[namespace] = newValue }
  }
}

// MARK: - Template

/// A string with `${{ … }}` holes. `render` interpolates scalars into text;
/// `renderValue` keeps the value's type when the whole string is exactly one
/// expression, which is how `set:` assigns an integer and `run:` env values
/// stay strings.
public nonisolated struct WorkflowTemplate: Equatable, Sendable, Hashable {
  public enum Segment: Equatable, Sendable, Hashable {
    case literal(String)
    case expression(WorkflowExpression)
  }

  public let source: String
  public let segments: [Segment]

  public static func parse(_ source: String) throws(WorkflowExpressionError) -> WorkflowTemplate {
    var segments: [Segment] = []
    var literal = ""
    var index = source.startIndex
    while index < source.endIndex {
      if source[index...].hasPrefix("${{") {
        guard let close = source.range(of: "}}", range: source.index(index, offsetBy: 3)..<source.endIndex)
        else {
          throw .syntax("unterminated `${{`", offset: source.distance(from: source.startIndex, to: index))
        }
        if !literal.isEmpty {
          segments.append(.literal(literal))
          literal = ""
        }
        let body = String(source[source.index(index, offsetBy: 3)..<close.lowerBound])
        segments.append(.expression(try WorkflowExpression.parse(body)))
        index = close.upperBound
      } else {
        literal.append(source[index])
        index = source.index(after: index)
      }
    }
    if !literal.isEmpty || segments.isEmpty {
      segments.append(.literal(literal))
    }
    return WorkflowTemplate(source: source, segments: segments)
  }

  /// A template with no holes; never throws.
  public static func literal(_ text: String) -> WorkflowTemplate {
    WorkflowTemplate(source: text, segments: [.literal(text)])
  }

  init(source: String, segments: [Segment]) {
    self.source = source
    self.segments = segments
  }

  public var isStatic: Bool {
    segments.allSatisfy {
      if case .literal = $0 { return true }
      return false
    }
  }

  /// The single expression when the template is exactly `${{ … }}`.
  public var soleExpression: WorkflowExpression? {
    guard segments.count == 1, case .expression(let expression) = segments[0] else { return nil }
    return expression
  }

  public var expressions: [WorkflowExpression] {
    segments.compactMap {
      if case .expression(let expression) = $0 { return expression }
      return nil
    }
  }

  public var references: [WorkflowReference] {
    var found: [WorkflowReference] = []
    for expression in expressions {
      for reference in expression.references where !found.contains(reference) {
        found.append(reference)
      }
    }
    return found
  }

  public var allReferences: [WorkflowReference] {
    var found: [WorkflowReference] = []
    for expression in expressions {
      for reference in expression.allReferences where !found.contains(reference) {
        found.append(reference)
      }
    }
    return found
  }

  public func render(in context: WorkflowContext) throws(WorkflowExpressionError) -> String {
    var output = ""
    for segment in segments {
      switch segment {
      case .literal(let text):
        output += text
      case .expression(let expression):
        let value = try expression.evaluate(in: context)
        guard let text = value.interpolatedText else {
          throw .typeMismatch("cannot interpolate a \(value.typeName) into text (`\(expression.source)`)")
        }
        output += text
      }
    }
    return output
  }

  public func renderValue(in context: WorkflowContext) throws(WorkflowExpressionError) -> WorkflowValue {
    if let expression = soleExpression {
      return try expression.evaluate(in: context)
    }
    return .string(try render(in: context))
  }
}

// MARK: - Lexer

extension WorkflowExpression {
  enum Token: Equatable {
    case number(Int)
    case string(String)
    case identifier(String)
    case punctuation(String)
    case end

    var description: String {
      switch self {
      case .number(let value): return "number \(value)"
      case .string(let value): return "string '\(value)'"
      case .identifier(let value): return "`\(value)`"
      case .punctuation(let value): return "`\(value)`"
      case .end: return "end of expression"
      }
    }
  }

  struct PositionedToken: Equatable {
    let token: Token
    let offset: Int
    /// Whether whitespace preceded the token — what disambiguates `a - b`
    /// from `a-b`.
    let precededBySpace: Bool
  }

  enum Lexer {
    private struct Cursor {
      let scalars: [Unicode.Scalar]
      var index = 0

      var atEnd: Bool { index >= scalars.count }
      var current: Unicode.Scalar { scalars[index] }
      func peek(_ offset: Int = 1) -> Unicode.Scalar? {
        let target = index + offset
        return target < scalars.count ? scalars[target] : nil
      }
    }

    static func tokenize(_ source: String) throws(WorkflowExpressionError) -> [PositionedToken] {
      var cursor = Cursor(scalars: Array(source.unicodeScalars))
      var tokens: [PositionedToken] = []
      var sawSpace = true
      while !cursor.atEnd {
        if cursor.current.properties.isWhitespace {
          sawSpace = true
          cursor.index += 1
          continue
        }
        let start = cursor.index
        let token: Token
        if isIdentifierStart(cursor.current) {
          token = .identifier(lexIdentifier(&cursor))
        } else if isDigit(cursor.current) {
          token = .number(try lexNumber(&cursor))
        } else if cursor.current == "'" || cursor.current == "\"" {
          token = .string(try lexString(&cursor))
        } else {
          token = .punctuation(try lexPunctuation(&cursor))
        }
        tokens.append(PositionedToken(token: token, offset: start, precededBySpace: sawSpace))
        sawSpace = false
      }
      tokens.append(PositionedToken(token: .end, offset: cursor.scalars.count, precededBySpace: true))
      return tokens
    }

    private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
      scalar.properties.isAlphabetic && scalar.isASCII || scalar == "_"
    }

    private static func isIdentifierBody(_ scalar: Unicode.Scalar) -> Bool {
      isIdentifierStart(scalar) || isDigit(scalar)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
      scalar.value >= 0x30 && scalar.value <= 0x39
    }

    private static func lexIdentifier(_ cursor: inout Cursor) -> String {
      var text = ""
      while !cursor.atEnd {
        let next = cursor.current
        if isIdentifierBody(next) {
          text.unicodeScalars.append(next)
        } else if next == "-", let following = cursor.peek(), isIdentifierBody(following) {
          // A hyphen inside a name: `max-rounds`. Requires a name character
          // right after it so `a- b` still fails loudly.
          text.unicodeScalars.append(next)
        } else {
          break
        }
        cursor.index += 1
      }
      return text
    }

    private static func lexNumber(_ cursor: inout Cursor) throws(WorkflowExpressionError) -> Int {
      let start = cursor.index
      var text = ""
      while !cursor.atEnd, isDigit(cursor.current) {
        text.unicodeScalars.append(cursor.current)
        cursor.index += 1
      }
      if !cursor.atEnd, cursor.current == "." {
        throw .syntax("decimal numbers are not supported", offset: start)
      }
      guard let value = Int(text) else { throw .overflow }
      return value
    }

    /// `'…'` with `''` as the escaped quote (GitHub Actions spelling), or
    /// `"…"` with backslash escapes.
    private static func lexString(_ cursor: inout Cursor) throws(WorkflowExpressionError) -> String {
      let start = cursor.index
      let quote = cursor.current
      var text = ""
      cursor.index += 1
      while !cursor.atEnd {
        let next = cursor.current
        if next == quote {
          if quote == "'", cursor.peek() == "'" {
            text.unicodeScalars.append("'")
            cursor.index += 2
            continue
          }
          cursor.index += 1
          return text
        }
        if quote == "\"", next == "\\", let escaped = cursor.peek() {
          text.unicodeScalars.append(escaped)
          cursor.index += 2
          continue
        }
        text.unicodeScalars.append(next)
        cursor.index += 1
      }
      throw .syntax("unterminated string", offset: start)
    }

    private static let twoCharacterOperators: Set<String> = ["==", "!=", "<=", ">=", "&&", "||", "??"]
    private static let oneCharacterOperators: Set<String> = ["!", "<", ">", "+", "-", "(", ")", ".", "[", "]", ","]

    private static func lexPunctuation(_ cursor: inout Cursor) throws(WorkflowExpressionError) -> String {
      let one = String(cursor.current)
      if let next = cursor.peek(), twoCharacterOperators.contains(one + String(next)) {
        cursor.index += 2
        return one + String(next)
      }
      if oneCharacterOperators.contains(one) {
        cursor.index += 1
        return one
      }
      throw .syntax("unexpected character `\(one)`", offset: cursor.index)
    }
  }

  // MARK: - Parser

  /// Precedence climbing over: `??` < `||` < `&&` < equality < comparison <
  /// additive < unary < postfix.
  struct Parser {
    private let tokens: [PositionedToken]
    private var position = 0

    init(tokens: [PositionedToken]) {
      self.tokens = tokens
    }

    var atEnd: Bool { current.token == .end }
    var currentOffset: Int { current.offset }
    var currentDescription: String { current.token.description }
    private var current: PositionedToken { tokens[position] }

    private mutating func advance() -> PositionedToken {
      let token = tokens[position]
      if position < tokens.count - 1 { position += 1 }
      return token
    }

    private mutating func consume(_ punctuation: String) -> Bool {
      if current.token == .punctuation(punctuation) {
        _ = advance()
        return true
      }
      return false
    }

    private mutating func expect(_ punctuation: String) throws(WorkflowExpressionError) {
      guard consume(punctuation) else {
        throw .syntax("expected `\(punctuation)`, found \(current.token.description)", offset: current.offset)
      }
    }

    mutating func parseExpression() throws(WorkflowExpressionError) -> Node {
      try parseCoalesce()
    }

    private mutating func parseCoalesce() throws(WorkflowExpressionError) -> Node {
      var lhs = try parseOr()
      while consume("??") {
        let rhs = try parseOr()
        lhs = .binary(.coalesce, lhs, rhs)
      }
      return lhs
    }

    private mutating func parseOr() throws(WorkflowExpressionError) -> Node {
      var lhs = try parseAnd()
      while consume("||") {
        let rhs = try parseAnd()
        lhs = .binary(.or, lhs, rhs)
      }
      return lhs
    }

    private mutating func parseAnd() throws(WorkflowExpressionError) -> Node {
      var lhs = try parseEquality()
      while consume("&&") {
        let rhs = try parseEquality()
        lhs = .binary(.and, lhs, rhs)
      }
      return lhs
    }

    private mutating func parseEquality() throws(WorkflowExpressionError) -> Node {
      var lhs = try parseComparison()
      while true {
        if consume("==") {
          lhs = .binary(.equal, lhs, try parseComparison())
        } else if consume("!=") {
          lhs = .binary(.notEqual, lhs, try parseComparison())
        } else {
          return lhs
        }
      }
    }

    private mutating func parseComparison() throws(WorkflowExpressionError) -> Node {
      var lhs = try parseAdditive()
      while true {
        if consume("<=") {
          lhs = .binary(.lessOrEqual, lhs, try parseAdditive())
        } else if consume(">=") {
          lhs = .binary(.greaterOrEqual, lhs, try parseAdditive())
        } else if consume("<") {
          lhs = .binary(.less, lhs, try parseAdditive())
        } else if consume(">") {
          lhs = .binary(.greater, lhs, try parseAdditive())
        } else {
          return lhs
        }
      }
    }

    private mutating func parseAdditive() throws(WorkflowExpressionError) -> Node {
      var lhs = try parseUnary()
      while true {
        if current.token == .punctuation("+") {
          _ = advance()
          lhs = .binary(.add, lhs, try parseUnary())
        } else if current.token == .punctuation("-") {
          let minus = current
          let next = tokens[min(position + 1, tokens.count - 1)]
          guard minus.precededBySpace, next.precededBySpace else {
            throw .syntax("binary `-` needs whitespace on both sides (`a - b`)", offset: minus.offset)
          }
          _ = advance()
          lhs = .binary(.subtract, lhs, try parseUnary())
        } else {
          return lhs
        }
      }
    }

    private mutating func parseUnary() throws(WorkflowExpressionError) -> Node {
      if consume("!") {
        return .unary(.not, try parseUnary())
      }
      if current.token == .punctuation("-") {
        _ = advance()
        return .unary(.negate, try parseUnary())
      }
      return try parsePostfix()
    }

    private mutating func parsePostfix() throws(WorkflowExpressionError) -> Node {
      var node = try parsePrimary()
      while true {
        if consume(".") {
          guard case .identifier(let name) = current.token else {
            throw .syntax("expected a name after `.`", offset: current.offset)
          }
          _ = advance()
          if case .reference(let path) = node {
            node = .reference(path + [name])
          } else {
            node = .index(node, .literal(.string(name)))
          }
        } else if consume("[") {
          let key = try parseExpression()
          try expect("]")
          node = .index(node, key)
        } else {
          return node
        }
      }
    }

    private mutating func parsePrimary() throws(WorkflowExpressionError) -> Node {
      let token = advance()
      switch token.token {
      case .number(let value):
        return .literal(.int(value))
      case .string(let value):
        return .literal(.string(value))
      case .identifier(let name):
        switch name {
        case "true": return .literal(.bool(true))
        case "false": return .literal(.bool(false))
        case "null": return .literal(.null)
        default: break
        }
        if consume("(") {
          var arguments: [Node] = []
          if !consume(")") {
            repeat {
              arguments.append(try parseExpression())
            } while consume(",")
            try expect(")")
          }
          return .call(name, arguments)
        }
        return .reference([name])
      case .punctuation("("):
        let inner = try parseExpression()
        try expect(")")
        return inner
      case .punctuation(let value):
        throw .syntax("unexpected `\(value)`", offset: token.offset)
      case .end:
        throw .syntax("unexpected end of expression", offset: token.offset)
      }
    }
  }

  // MARK: - Evaluator

  struct Evaluator {
    let context: WorkflowContext

    func evaluate(_ node: Node) throws(WorkflowExpressionError) -> WorkflowValue {
      switch node {
      case .literal(let value):
        return value
      case .reference(let path):
        guard let value = context.value(at: path) else {
          throw .missingReference(WorkflowReference(path: path))
        }
        return value
      case .index(let base, let key):
        return try evaluateIndex(base, key)
      case .unary(let op, let operand):
        return try evaluateUnary(op, operand)
      case .binary(let op, let lhs, let rhs):
        switch op {
        case .coalesce, .and, .or, .equal, .notEqual:
          return try evaluateLogical(op, lhs, rhs)
        case .add, .subtract, .less, .lessOrEqual, .greater, .greaterOrEqual:
          return try evaluateArithmetic(op, lhs, rhs)
        }
      case .call(let name, let arguments):
        return try evaluateCall(name, arguments)
      }
    }

    private func evaluateIndex(_ base: Node, _ keyNode: Node) throws(WorkflowExpressionError) -> WorkflowValue {
      let container = try evaluate(base)
      let key = try evaluate(keyNode)
      switch (container, key) {
      case (.object(let object), .string(let name)):
        guard let value = object[name] else {
          throw .missingReference(WorkflowReference(path: [describe(base), name]))
        }
        return value
      case (.array(let array), .int(let index)):
        guard array.indices.contains(index) else {
          throw .typeMismatch("index \(index) is out of range")
        }
        return array[index]
      default:
        throw .typeMismatch("cannot index a \(container.typeName) with a \(key.typeName)")
      }
    }

    private func evaluateUnary(_ op: UnaryOperator, _ operand: Node) throws(WorkflowExpressionError) -> WorkflowValue {
      let value = try evaluate(operand)
      switch op {
      case .not:
        guard let flag = value.boolValue else {
          throw .typeMismatch("`!` needs a boolean, got \(value.typeName)")
        }
        return .bool(!flag)
      case .negate:
        guard let number = value.intValue else {
          throw .typeMismatch("unary `-` needs a number, got \(value.typeName)")
        }
        return .int(-number)
      }
    }

    private func evaluateLogical(_ op: BinaryOperator, _ lhsNode: Node, _ rhsNode: Node)
      throws(WorkflowExpressionError) -> WorkflowValue
    {
      switch op {
      case .coalesce:
        do {
          let lhs = try evaluate(lhsNode)
          if !lhs.isNull { return lhs }
        } catch .missingReference {
          // Absence is exactly what `??` is for.
        }
        return try evaluate(rhsNode)
      case .and:
        let lhs = try boolean(lhsNode, for: "&&")
        if !lhs { return .bool(false) }
        return .bool(try boolean(rhsNode, for: "&&"))
      case .or:
        let lhs = try boolean(lhsNode, for: "||")
        if lhs { return .bool(true) }
        return .bool(try boolean(rhsNode, for: "||"))
      case .equal:
        return .bool(try evaluate(lhsNode) == evaluate(rhsNode))
      case .notEqual:
        return .bool(try evaluate(lhsNode) != evaluate(rhsNode))
      default:
        throw .typeMismatch("`\(symbol(op))` is not a logical operator")
      }
    }

    private func boolean(_ node: Node, for op: String) throws(WorkflowExpressionError) -> Bool {
      let value = try evaluate(node)
      guard let flag = value.boolValue else {
        throw .typeMismatch("`\(op)` needs booleans, got \(value.typeName)")
      }
      return flag
    }

    private func evaluateArithmetic(_ op: BinaryOperator, _ lhsNode: Node, _ rhsNode: Node)
      throws(WorkflowExpressionError) -> WorkflowValue
    {
      let lhs = try evaluate(lhsNode)
      let rhs = try evaluate(rhsNode)
      guard let a = lhs.intValue, let b = rhs.intValue else {
        throw .typeMismatch("`\(symbol(op))` needs numbers, got \(lhs.typeName) and \(rhs.typeName)")
      }
      switch op {
      case .add:
        let (sum, overflow) = a.addingReportingOverflow(b)
        if overflow { throw .overflow }
        return .int(sum)
      case .subtract:
        let (difference, overflow) = a.subtractingReportingOverflow(b)
        if overflow { throw .overflow }
        return .int(difference)
      case .less: return .bool(a < b)
      case .lessOrEqual: return .bool(a <= b)
      case .greater: return .bool(a > b)
      case .greaterOrEqual: return .bool(a >= b)
      default: throw .typeMismatch("`\(symbol(op))` is not an arithmetic operator")
      }
    }

    private func evaluateCall(_ name: String, _ arguments: [Node]) throws(WorkflowExpressionError) -> WorkflowValue {
      switch name {
      case "exists":
        guard arguments.count == 1 else { throw .arity(function: name, expected: 1) }
        do {
          return .bool(!(try evaluate(arguments[0])).isNull)
        } catch .missingReference {
          return .bool(false)
        }
      case "length":
        guard arguments.count == 1 else { throw .arity(function: name, expected: 1) }
        return try length(of: try evaluate(arguments[0]))
      case "contains", "startsWith", "endsWith":
        guard arguments.count == 2 else { throw .arity(function: name, expected: 2) }
        return try stringPredicate(name, try evaluate(arguments[0]), try evaluate(arguments[1]))
      default:
        throw .unknownFunction(name)
      }
    }

    private func length(of value: WorkflowValue) throws(WorkflowExpressionError) -> WorkflowValue {
      switch value {
      case .string(let text): return .int(text.count)
      case .array(let items): return .int(items.count)
      case .object(let members): return .int(members.count)
      default: throw .typeMismatch("`length` needs a string, array, or object, got \(value.typeName)")
      }
    }

    private func stringPredicate(_ name: String, _ haystack: WorkflowValue, _ needle: WorkflowValue)
      throws(WorkflowExpressionError) -> WorkflowValue
    {
      if case .array(let items) = haystack, name == "contains" {
        return .bool(items.contains(needle))
      }
      guard let text = haystack.stringValue, let part = needle.stringValue else {
        throw .typeMismatch("`\(name)` needs strings, got \(haystack.typeName) and \(needle.typeName)")
      }
      switch name {
      case "contains": return .bool(text.contains(part))
      case "startsWith": return .bool(text.hasPrefix(part))
      default: return .bool(text.hasSuffix(part))
      }
    }

    private func symbol(_ op: BinaryOperator) -> String {
      switch op {
      case .add: return "+"
      case .subtract: return "-"
      case .less: return "<"
      case .lessOrEqual: return "<="
      case .greater: return ">"
      case .greaterOrEqual: return ">="
      case .equal: return "=="
      case .notEqual: return "!="
      case .and: return "&&"
      case .or: return "||"
      case .coalesce: return "??"
      }
    }

    private func describe(_ node: Node) -> String {
      if case .reference(let path) = node { return path.joined(separator: ".") }
      return "<expression>"
    }
  }
}
