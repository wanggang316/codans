import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// `EnvVarValidator` is a pure free enum — these tests hit it without
/// SwiftUI ceremony. The Draft / commit logic in the SwiftUI view itself
/// uses these same rules, so verifying the validator is sufficient
/// coverage for the "rejected input never calls onChange" contract.
struct EnvironmentEditorValidationTests {
  @Test
  func keyWithSpaceIsRejected() {
    #expect(EnvVarValidator.errorFor(key: "FOO BAR", value: "x", existing: [:]) == "Invalid key")
  }

  @Test
  func keyStartingWithDigitIsRejected() {
    #expect(EnvVarValidator.errorFor(key: "1FOO", value: "x", existing: [:]) == "Invalid key")
  }

  @Test
  func keyWithDashIsRejected() {
    #expect(EnvVarValidator.errorFor(key: "FOO-BAR", value: "x", existing: [:]) == "Invalid key")
  }

  @Test
  func validKeyIsAccepted() {
    #expect(EnvVarValidator.errorFor(key: "FOO", value: "x", existing: [:]) == nil)
    #expect(EnvVarValidator.errorFor(key: "_PRIVATE", value: "x", existing: [:]) == nil)
    #expect(EnvVarValidator.errorFor(key: "PATH_2", value: "x", existing: [:]) == nil)
  }

  @Test
  func valueWithLineFeedIsRejected() {
    #expect(
      EnvVarValidator.errorFor(key: "FOO", value: "line1\nline2", existing: [:])
        == "Value cannot contain newlines"
    )
  }

  @Test
  func valueWithCarriageReturnIsRejected() {
    #expect(
      EnvVarValidator.errorFor(key: "FOO", value: "line1\rline2", existing: [:])
        == "Value cannot contain newlines"
    )
  }

  @Test
  func duplicateKeyIsRejected() {
    let existing = ["FOO": "bar"]
    #expect(
      EnvVarValidator.errorFor(key: "FOO", value: "baz", existing: existing)
        == "Key already exists"
    )
  }

  @Test
  func reservedBuiltinKeysAreRejected() {
    // The two app-provided path variables are pinned as read-only rows;
    // a user can't redefine them as editable entries.
    for builtin in BuiltinEnvVar.allCases {
      #expect(
        EnvVarValidator.errorFor(key: builtin.key, value: "x", existing: [:])
          == "Reserved by touch-code"
      )
    }
  }

  @Test
  func emptyKeyDoesNotErrorButDoesNotCommit() {
    // Empty key is "incomplete" — the validator is permissive (no error
    // string) so the user can finish typing without a flash of red. The
    // commit path checks `!key.isEmpty` separately.
    #expect(EnvVarValidator.errorFor(key: "", value: "x", existing: [:]) == nil)
  }

  @Test
  func keyValidationAcceptsAllPosixCharacters() {
    #expect(EnvVarValidator.keyIsValidPOSIX("ABC_def_123") == true)
    #expect(EnvVarValidator.keyIsValidPOSIX("a") == true)
    #expect(EnvVarValidator.keyIsValidPOSIX("_") == true)
  }

  @Test
  func keyValidationRejectsUnicodeLetters() {
    // POSIX env-var KEY rule is strictly ASCII letters / digits / underscore.
    #expect(EnvVarValidator.keyIsValidPOSIX("名前") == false)
    #expect(EnvVarValidator.keyIsValidPOSIX("FOO世界") == false)
  }
}
