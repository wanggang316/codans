import CodansCore
import Foundation
import Testing

/// `$CODANS_RUNTIME_DIR` / `$CODANS_CACHE_DIR` seams and the
/// `~/.codans[-dev]/run` default (`AppDirectories.runtimeDirectory`). The
/// runtime root holds the zmx daemon sockets: an isolated instance must
/// never resolve it into the user's real one, and it must stay out of
/// `~/Library/Caches`, which cache cleaners wipe wholesale.
struct AppDirectoriesRuntimeDirectoryTests {
  private static let home = URL(fileURLWithPath: "/tmp/fake-home")
  /// `~/.codans` for Release test runs, `~/.codans-dev` for Debug.
  private static let root = "/tmp/fake-home/.\(AppDirectories.name)"

  @Test
  func defaultsToRunUnderTheChannelRoot() {
    let url = AppDirectories.runtimeDirectory(home: Self.home, override: nil, cacheOverride: nil)
    #expect(url.path == "\(Self.root)/run")
  }

  @Test
  func explicitOverrideRelocatesTheRuntimeRoot() {
    let url = AppDirectories.runtimeDirectory(
      home: Self.home, override: "/tmp/codans-iso-run", cacheOverride: "/tmp/codans-iso-cache"
    )
    #expect(url.path == "/tmp/codans-iso-run")
  }

  @Test
  func cacheOverrideAloneNestsTheRuntimeRootInsideIt() {
    // A harness that isolates only the cache (the seam that predates the
    // runtime root) must still get private daemons.
    let url = AppDirectories.runtimeDirectory(
      home: Self.home, override: nil, cacheOverride: "/tmp/codans-iso-cache"
    )
    #expect(url.path == "/tmp/codans-iso-cache/run")
  }

  @Test
  func emptyOverridesFallBackToTheChannelRoot() {
    let url = AppDirectories.runtimeDirectory(home: Self.home, override: "", cacheOverride: "")
    #expect(url.path == "\(Self.root)/run")
  }

  @Test
  func runtimeRootIsNotUnderTheCacheRoot() {
    let runtime = AppDirectories.runtimeDirectory(override: nil, cacheOverride: nil)
    let cache = AppDirectories.cacheDirectory(override: nil)
    #expect(!runtime.path.hasPrefix(cache.path))
    #expect(!runtime.path.contains("/Library/Caches/"))
  }
}
