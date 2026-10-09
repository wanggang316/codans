import Foundation
import Testing

@testable import CodansCore

/// The expression language is the one piece of the workflow DSL every other
/// piece leans on — conditions, templates, skip-consequence analysis — so
/// its grammar and its reference analysis are pinned here.
struct WorkflowExpressionTests {
  private let context = WorkflowContext([
    "inputs": ["max-rounds": 3, "focus": "tests", "flag": true],
    "state": ["round": 1, "verdict": "issues"],
    "deliveries": ["review": ["path": "/w/.codans/workflow-runs/r/deliveries/review.md", "verdict": "issues"]],
    "steps": ["lint": ["outcome": "success", "outputs": ["exit-code": 0, "stdout": "ok\n"]]],
    "roles": ["reviewer": ["state": "idle", "agent": "codex"]],
    "loop": ["iteration": .null],
  ])

  private func eval(_ source: String) throws -> WorkflowValue {
    try WorkflowExpression.parse(source).evaluate(in: context)
  }

  // MARK: - Literals and references

  @Test
  func literalsEvaluateToThemselves() throws {
    #expect(try eval("42") == .int(42))
    #expect(try eval("'it''s'") == .string("it's"))
    #expect(try eval("\"quoted \\\"x\\\"\"") == .string("quoted \"x\""))
    #expect(try eval("true") == .bool(true))
    #expect(try eval("null") == .null)
  }

  @Test
  func dottedAndBracketReferencesResolve() throws {
    #expect(try eval("state.round") == .int(1))
    #expect(try eval("inputs.max-rounds") == .int(3))
    #expect(try eval("steps.lint.outputs.exit-code") == .int(0))
    #expect(try eval("deliveries['review'].verdict") == .string("issues"))
  }

  @Test
  func missingReferenceIsAnError() {
    #expect(throws: WorkflowExpressionError.missingReference(WorkflowReference(path: ["deliveries", "fixes", "path"]))) {
      try eval("deliveries.fixes.path")
    }
  }

  @Test
  func wrappedFormIsAccepted() throws {
    #expect(try eval("${{ state.round + 1 }}") == .int(2))
  }

  // MARK: - Operators

  @Test
  func arithmeticAndComparison() throws {
    #expect(try eval("state.round + 1") == .int(2))
    #expect(try eval("inputs.max-rounds - state.round") == .int(2))
    #expect(try eval("state.round < inputs.max-rounds") == .bool(true))
    #expect(try eval("state.round >= 1 && state.verdict == 'issues'") == .bool(true))
    #expect(try eval("state.verdict != 'issues' || inputs.flag") == .bool(true))
    #expect(try eval("!inputs.flag") == .bool(false))
    #expect(try eval("-state.round") == .int(-1))
    #expect(try eval("(1 + 2) - 3 == 0") == .bool(true))
  }

  @Test
  func binaryMinusNeedsWhitespaceBecauseNamesMayContainHyphens() throws {
    // `round-1` is a name, exactly as `max-rounds` is.
    let hyphenated = try WorkflowExpression.parse("state.round-1")
    #expect(hyphenated.references.map(\.description) == ["state.round-1"])
    #expect(throws: WorkflowExpressionError.self) {
      try WorkflowExpression.parse("state.round -1")
    }
    #expect(throws: WorkflowExpressionError.self) {
      try WorkflowExpression.parse("state.round- 1")
    }
  }

  @Test
  func conditionsMustBeBoolean() {
    #expect(throws: WorkflowExpressionError.self) {
      try WorkflowExpression.parse("state.round").evaluateCondition(in: context)
    }
    #expect(throws: WorkflowExpressionError.self) {
      try eval("'a' + 1")
    }
    #expect(throws: WorkflowExpressionError.self) {
      try eval("1 && true")
    }
  }

  @Test
  func coalesceAndExistsTolerateAbsence() throws {
    #expect(try eval("deliveries.fixes.path ?? 'none'") == .string("none"))
    #expect(try eval("loop.iteration ?? 0") == .int(0))
    #expect(try eval("exists(deliveries.fixes.path)") == .bool(false))
    #expect(try eval("exists(deliveries.review.path)") == .bool(true))
    #expect(try eval("exists(loop.iteration)") == .bool(false))
    #expect(try eval("!exists(deliveries.fixes) || deliveries.fixes.verdict == 'x'") == .bool(true))
  }

  @Test
  func stringFunctions() throws {
    #expect(try eval("contains(steps.lint.outputs.stdout, 'ok')") == .bool(true))
    #expect(try eval("startsWith(inputs.focus, 'te')") == .bool(true))
    #expect(try eval("endsWith(inputs.focus, 'x')") == .bool(false))
    #expect(try eval("length(inputs.focus)") == .int(5))
    #expect(throws: WorkflowExpressionError.unknownFunction("toJSON")) {
      try eval("toJSON(inputs)")
    }
    #expect(throws: WorkflowExpressionError.arity(function: "contains", expected: 2)) {
      try eval("contains('a')")
    }
  }

  @Test
  func syntaxErrorsCarryOffsets() {
    #expect(throws: WorkflowExpressionError.self) { try WorkflowExpression.parse("1 +") }
    #expect(throws: WorkflowExpressionError.self) { try WorkflowExpression.parse("'open") }
    #expect(throws: WorkflowExpressionError.self) { try WorkflowExpression.parse("1.5") }
    #expect(throws: WorkflowExpressionError.self) { try WorkflowExpression.parse("a b") }
    #expect(throws: WorkflowExpressionError.self) { try WorkflowExpression.parse("a $ b") }
  }

  // MARK: - Reference analysis

  @Test
  func requiredReferencesExcludeGuardedOnes() throws {
    let expression = try WorkflowExpression.parse(
      "state.round < 3 && (deliveries.fixes.path ?? deliveries.review.path) != '' && exists(deliveries.late.path)")
    #expect(expression.references.map(\.description) == ["state.round"])
    #expect(
      expression.allReferences.map(\.description) == [
        "state.round", "deliveries.fixes.path", "deliveries.review.path", "deliveries.late.path",
      ])
  }

  @Test
  func bracketPathsWithLiteralKeysFlattenIntoReferences() throws {
    let expression = try WorkflowExpression.parse("steps['run-tests'].outputs.exit-code == 0")
    #expect(expression.references.map(\.description) == ["steps.run-tests.outputs.exit-code"])
  }

  // MARK: - Templates

  @Test
  func templatesInterpolateScalarsAndKeepSoleExpressionTypes() throws {
    let text = try WorkflowTemplate.parse("Round ${{ state.round }} of ${{ inputs.max-rounds }}: ${{ state.verdict }}")
    #expect(try text.render(in: context) == "Round 1 of 3: issues")
    #expect(text.references.map(\.description) == ["state.round", "inputs.max-rounds", "state.verdict"])

    let sole = try WorkflowTemplate.parse("${{ state.round + 1 }}")
    #expect(try sole.renderValue(in: context) == .int(2))
    #expect(try sole.render(in: context) == "2")

    let literal = try WorkflowTemplate.parse("no holes here")
    #expect(literal.isStatic)
    #expect(try literal.renderValue(in: context) == .string("no holes here"))
  }

  @Test
  func templatesRejectUnterminatedHolesAndNonScalarInterpolation() {
    #expect(throws: WorkflowExpressionError.self) { try WorkflowTemplate.parse("${{ oops") }
    #expect(throws: WorkflowExpressionError.self) {
      try WorkflowTemplate.parse("all: ${{ inputs }}").render(in: context)
    }
  }
}
