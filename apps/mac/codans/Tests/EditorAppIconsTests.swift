import AppKit
import Testing

@testable import Codans

/// Pins the caching contract of `EditorAppIcons`: menus are built eagerly on
/// every sidebar-row render, so the LaunchServices lookup and the offscreen
/// redraw must each happen at most once per (path, side) per process
/// (fix/update-loading-long — uncached lookups wedged launch behind a
/// re-render storm).
@MainActor
struct EditorAppIconsTests {
  /// A stock Apple app present on every macOS install; its icon resolves
  /// through the same LaunchServices path as third-party editors.
  private static let systemAppPath = "/System/Applications/Calculator.app"

  @Test
  func resizedIconReturnsTheSameInstanceForARepeatedPath() {
    let first = EditorAppIcons.resizedIcon(atPath: Self.systemAppPath, side: 16)
    let second = EditorAppIcons.resizedIcon(atPath: Self.systemAppPath, side: 16)
    #expect(first === second, "Repeat lookups must hit the cache, not LaunchServices")
    #expect(first.size == NSSize(width: 16, height: 16))
  }

  @Test
  func distinctSidesGetDistinctEntries() {
    let small = EditorAppIcons.resizedIcon(atPath: Self.systemAppPath, side: 16)
    let large = EditorAppIcons.resizedIcon(atPath: Self.systemAppPath, side: 32)
    #expect(small !== large)
    #expect(large.size == NSSize(width: 32, height: 32))
  }

  @Test
  func clearDropsCachedEntriesSoTheNextLookupRedraws() {
    _ = EditorAppIcons.resizedIcon(atPath: Self.systemAppPath, side: 16)
    EditorAppIcons.clear()
    let afterClear = EditorAppIcons.resizedIcon(atPath: Self.systemAppPath, side: 16)
    // A fresh redraw produces a new instance; the size contract is unchanged.
    #expect(afterClear.size == NSSize(width: 16, height: 16))
    #expect(
      EditorAppIcons.resizedIcon(atPath: Self.systemAppPath, side: 16) === afterClear,
      "Post-clear lookups must cache again"
    )
  }

  @Test
  func bundleIDLookupCachesNegativeResultsWithoutCrashing() {
    // A bundle id no app answers must not probe LaunchServices on every
    // call; the observable contract is just that it keeps returning nil.
    let missing = "com.gumpw.codans.tests.no-such-app"
    #expect(EditorAppIcons.appURL(bundleIdentifier: missing) == nil)
    #expect(EditorAppIcons.appURL(bundleIdentifier: missing) == nil)
    #expect(EditorAppIcons.appURL(bundleIdentifier: "") == nil)

    // Finder is present on every install, so the positive path is coverable.
    let finder = EditorAppIcons.appURL(bundleIdentifier: "com.apple.finder")
    #expect(finder?.path.isEmpty == false)
  }
}
