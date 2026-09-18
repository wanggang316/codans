import CodansCore
import Foundation
import Testing

/// `$CODANS_CONFIG_DIR` isolation seam (`AppDirectories.configDirectory`).
/// Relocating the config root is what lets an end-to-end smoke run drive a real
/// Debug app + CLI without mutating the user's real `~/.config/codans[-dev]/`.
struct AppDirectoriesConfigOverrideTests {
  @Test func workflowsUseOneUserLevelRoot() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    #expect(AppDirectories.workflowDirectory(home: home).path == "/Users/example/.codans/workflows")
  }

  @Test
  func overrideRelocatesConfigRootEntirely() {
    let url = AppDirectories.configDirectory(
      home: URL(fileURLWithPath: "/tmp/fake-home"),
      override: "/tmp/codans-iso-123"
    )
    // The override replaces the whole `<home>/.config/<name>` path.
    #expect(url.path == "/tmp/codans-iso-123")
  }

  @Test
  func nilOverrideFallsBackToBuildSuffixedHomeDefault() {
    let url = AppDirectories.configDirectory(
      home: URL(fileURLWithPath: "/tmp/fake-home"),
      override: nil
    )
    #expect(url.path == "/tmp/fake-home/.config/\(AppDirectories.name)")
  }

  @Test
  func emptyOverrideFallsBackToBuildSuffixedHomeDefault() {
    let url = AppDirectories.configDirectory(
      home: URL(fileURLWithPath: "/tmp/fake-home"),
      override: ""
    )
    #expect(url.path == "/tmp/fake-home/.config/\(AppDirectories.name)")
  }

  @Test
  func settingsAndCatalogShareTheOverriddenRoot() {
    // The seam must cover the whole config surface, not just one file: both
    // settings.json and catalog.json resolve under the same overridden root,
    // so an isolated run's stores stay together.
    let root = "/tmp/codans-iso-xyz"
    let home = URL(fileURLWithPath: "/tmp/fake-home")
    // defaultURL(home:) forwards to configDirectory, which honors the env
    // override; pass it explicitly here for determinism.
    let configRoot = AppDirectories.configDirectory(home: home, override: root)
    #expect(configRoot.appendingPathComponent("settings.json").path == "/tmp/codans-iso-xyz/settings.json")
    #expect(configRoot.appendingPathComponent("catalog.json").path == "/tmp/codans-iso-xyz/catalog.json")
  }

  @Test
  func overrideRelocatesCacheRootEntirely() {
    let url = AppDirectories.cacheDirectory(override: "/tmp/codans-isolated-cache")
    #expect(url.path == "/tmp/codans-isolated-cache")
  }

  @Test
  func nilCacheOverrideUsesBuildSuffixedSystemCache() throws {
    let systemCache = try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    let url = AppDirectories.cacheDirectory(override: nil)
    #expect(url == systemCache.appendingPathComponent(AppDirectories.name, isDirectory: true))
  }

  @Test
  func emptyCacheOverrideUsesDefaultInsteadOfCurrentDirectory() {
    #expect(AppDirectories.cacheDirectory(override: "") == AppDirectories.cacheDirectory(override: nil))
  }

}
