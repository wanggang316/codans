import Foundation
import Testing

@testable import CodansCore

struct GitShaValidatorTests {
  @Test
  func acceptsSevenLowerHex() {
    #expect(GitShaValidator.isValid("abc1234"))
    #expect(GitShaValidator.isValid("0000000"))
    #expect(GitShaValidator.isValid("deadbee"))
  }

  @Test
  func acceptsSevenUpperHex() {
    #expect(GitShaValidator.isValid("ABC1234"))
    #expect(GitShaValidator.isValid("DEADBEE"))
  }

  @Test
  func acceptsFullSHA1() {
    #expect(GitShaValidator.isValid(String(repeating: "a", count: 40)))
  }

  @Test
  func acceptsFullSHA256() {
    #expect(GitShaValidator.isValid(String(repeating: "f", count: 64)))
  }

  @Test
  func acceptsMixedCase() {
    #expect(GitShaValidator.isValid("AbCdEf1234567"))
  }

  @Test
  func rejectsSixChars() {
    #expect(!GitShaValidator.isValid("abc123"))
  }

  @Test
  func rejects65Chars() {
    #expect(!GitShaValidator.isValid(String(repeating: "a", count: 65)))
  }

  @Test
  func rejectsNonHexChar() {
    #expect(!GitShaValidator.isValid("abc123g"))
    #expect(!GitShaValidator.isValid("1234567z"))
  }

  @Test
  func rejectsEmpty() {
    #expect(!GitShaValidator.isValid(""))
  }

  @Test
  func rejectsWhitespace() {
    #expect(!GitShaValidator.isValid("  abc1234  "))
    #expect(!GitShaValidator.isValid("abc 1234"))
  }
}
