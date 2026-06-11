import Foundation

/// Validates git commit SHAs. Accepts 7..64 hexadecimal characters (upper- or lower-case),
/// covering both SHA-1 (40 chars) and SHA-256 (64 chars) as well as abbreviated identifiers.
/// Callers use this to guard `git show <sha>` invocations against injection.
public nonisolated enum GitShaValidator {
  public static func isValid(_ candidate: String) -> Bool {
    let count = candidate.count
    guard count >= 7, count <= 64 else { return false }
    return candidate.allSatisfy { char in
      switch char {
      case "0"..."9", "a"..."f", "A"..."F": return true
      default: return false
      }
    }
  }
}
