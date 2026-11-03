import CodansCore
import Testing

struct UntrustedDisplayTextTests {
  @Test
  func removesBidiOverridesAndInvisibleFormatting() {
    #expect(UntrustedDisplayText.sanitized("\u{202E}evil\u{202C}") == "evil")
    #expect(UntrustedDisplayText.sanitized("a\u{200B}b\u{2066}c\u{FEFF}\u{061C}") == "abc")
  }

  @Test
  func keepsVisibleTextUnchanged() {
    #expect(UntrustedDisplayText.sanitized("✳ Running tests…") == "✳ Running tests…")
    #expect(UntrustedDisplayText.sanitized("  spaced  ") == "  spaced  ")
  }

  @Test
  func emptyResultReadsAsAbsent() {
    #expect(UntrustedDisplayText.sanitized(nil) == nil)
    #expect(UntrustedDisplayText.sanitized("") == nil)
    #expect(UntrustedDisplayText.sanitized("\u{200B}\u{202E}") == nil)
  }
}
