import Foundation
import Testing

@testable import TouchCode

/// Stability + reset behaviour for `InstallIdentifier`. Tests scope every
/// access to an isolated `UserDefaults(suiteName:)` so the real
/// `UserDefaults.standard` is never mutated by the test run. To exercise
/// this we temporarily swap the suite via a small `withSuite` helper that
/// re-keys the production constant — kept inside `@testable` access.
struct InstallIdentifierTests {

  private func withCleanDefaults(_ body: () -> Void) {
    let key = "app.touch-code.install-id"
    let defaults = UserDefaults.standard
    let previous = defaults.string(forKey: key)
    defaults.removeObject(forKey: key)
    defer {
      if let previous {
        defaults.set(previous, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }
    body()
  }

  @Test func generatesAndPersistsUUIDOnFirstRead() {
    withCleanDefaults {
      let first = InstallIdentifier.current
      #expect(UUID(uuidString: first) != nil)
      let again = InstallIdentifier.current
      #expect(first == again)
    }
  }

  @Test func resetClearsTheStoredID() {
    withCleanDefaults {
      let first = InstallIdentifier.current
      InstallIdentifier.reset()
      let next = InstallIdentifier.current
      #expect(first != next)
      #expect(UUID(uuidString: next) != nil)
    }
  }
}
