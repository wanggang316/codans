import CodansIPC
import Foundation
import Testing

@testable import CodansKit

/// The workflow error codes are a contract with scripts: each one maps to
/// exactly one exit code and survives the `IPCError.domain` pass-through.
struct WorkflowErrorCodeTests {
  private static let expected: [(CLIErrorCode, CLIExitCode)] = [
    (.workflowNotFound, .notFound),
    (.runNotFound, .notFound),
    (.paneBusy, .conflict),
    (.stepNotExpecting, .conflict),
    (.roleMismatch, .conflict),
    (.tokenRequired, .conflict),
    (.tokenInvalid, .conflict),
    (.workflowDisabled, .conflict),
    (.workflowTrustRequired, .conflict),
    (.inputRequired, .userError),
    (.profileRequired, .userError),
    (.sourceRequired, .userError),
    (.outputInvalid, .userError),
    (.verdictRequired, .userError),
    (.renderedTextInvalid, .userError),
    (.workflowInvalid, .userError),
    (.outputTooLarge, .userError),
  ]

  @Test
  func everyDomainCodeHasOneExitCode() {
    for (code, exit) in Self.expected {
      #expect(code.domainExitCode == exit, "\(code.rawValue)")
      #expect(CLIErrorCode(domainCode: code.rawValue) == code)
      #expect(CLIExitCode.from(.domain(code: code.rawValue, message: "", hint: nil)) == exit)
    }
  }

  @Test
  func rawValuesAreTheDocumentedStrings() {
    let raw = Set(Self.expected.map(\.0.rawValue))
    #expect(
      raw == [
        "WORKFLOW_NOT_FOUND", "WORKFLOW_INVALID", "WORKFLOW_DISABLED", "WORKFLOW_TRUST_REQUIRED",
        "RUN_NOT_FOUND", "SOURCE_REQUIRED", "INPUT_REQUIRED", "PROFILE_REQUIRED", "PANE_BUSY",
        "ROLE_MISMATCH", "STEP_NOT_EXPECTING", "TOKEN_REQUIRED", "TOKEN_INVALID", "OUTPUT_INVALID",
        "OUTPUT_TOO_LARGE", "VERDICT_REQUIRED", "RENDERED_TEXT_INVALID",
      ])
  }

  @Test
  func genericCodesAreNotDomainCodes() {
    // A server must not smuggle a generic outcome through `.domain`; the
    // CLI treats it as unknown and exits `internal`.
    #expect(CLIErrorCode(domainCode: "NOT_FOUND") == nil)
    #expect(CLIErrorCode(domainCode: "EMPTY_INPUT") == nil)
    #expect(CLIErrorCode.notFound.domainExitCode == nil)
    #expect(CLIExitCode.from(.domain(code: "NOT_FOUND", message: "", hint: nil)) == .internal)
    #expect(CLIExitCode.from(.domain(code: "SOMETHING_NEW", message: "", hint: nil)) == .internal)
  }

  @Test
  func keyValuePairsParse() throws {
    let parsed = try CLIKeyValuePairs.parse(["reviewer=auto", "author=p3", "note=a=b"], option: "--role")
    #expect(parsed == ["reviewer": "auto", "author": "p3", "note": "a=b"])
    #expect(try CLIKeyValuePairs.parse([], option: "--role").isEmpty)
    #expect(try CLIKeyValuePairs.parse(["empty="], option: "--input") == ["empty": ""])
  }

  @Test
  func keyValuePairsRejectMalformedAndDuplicateKeys() {
    #expect(throws: CLIArgumentError.invalidKeyValue(message: "--role expects name=value, got \"reviewer\"")) {
      try CLIKeyValuePairs.parse(["reviewer"], option: "--role")
    }
    #expect(throws: CLIArgumentError.invalidKeyValue(message: "--role expects name=value, got \"=auto\"")) {
      try CLIKeyValuePairs.parse(["=auto"], option: "--role")
    }
    #expect(throws: CLIArgumentError.invalidKeyValue(message: "--input scope given more than once")) {
      try CLIKeyValuePairs.parse(["scope=src", "scope=tests"], option: "--input")
    }
  }
}
