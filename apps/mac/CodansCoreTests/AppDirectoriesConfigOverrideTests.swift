import Foundation
import Testing
import CodansCore

/// `$CODANS_CONFIG_DIR` / `$CODANS_STATE_DIR` isolation seams and the
/// `~/.codans/{config,state}[-dev]` defaults (`AppDirectories`).
/// Relocating the roots is what lets an end-to-end smoke run drive a real
/// Debug app + CLI without mutating the user's real `~/.codans/`.
struct AppDirectoriesConfigOverrideTests {
  private static let home = URL(fileURLWithPath: "/tmp/fake-home")
  private static let devSuffix = BuildChannel.current == .development ? "-dev" : ""

  @Test
  func overrideRelocatesConfigRootEntirely() {
    let url = AppDirectories.configDirectory(home: Self.home, override: "/tmp/codans-iso-123")
    #expect(url.path == "/tmp/codans-iso-123")
  }

  @Test
  func nilOverrideFallsBackToChannelScopedConfigDefault() {
    let url = AppDirectories.configDirectory(home: Self.home, override: nil)
    #expect(url.path == "/tmp/fake-home/.codans/config\(Self.devSuffix)")
  }

  @Test
  func emptyOverrideFallsBackToChannelScopedConfigDefault() {
    let url = AppDirectories.configDirectory(home: Self.home, override: "")
    #expect(url.path == "/tmp/fake-home/.codans/config\(Self.devSuffix)")
  }

  @Test
  func stateDefaultsToChannelScopedSiblingOfConfig() {
    let url = AppDirectories.stateDirectory(home: Self.home, override: nil, configOverride: nil)
    #expect(url.path == "/tmp/fake-home/.codans/state\(Self.devSuffix)")
  }

  @Test
  func configOverrideAloneRelocatesStateToo() {
    // A smoke run that only sets CODANS_CONFIG_DIR must keep every store,
    // state included, out of the user's real root.
    let root = "/tmp/codans-iso-xyz"
    let config = AppDirectories.configDirectory(home: Self.home, override: root)
    let state = AppDirectories.stateDirectory(home: Self.home, override: nil, configOverride: root)
    #expect(config.appendingPathComponent("settings.json").path == "/tmp/codans-iso-xyz/settings.json")
    #expect(state.appendingPathComponent("catalog.json").path == "/tmp/codans-iso-xyz/catalog.json")
  }

  @Test
  func stateOverrideWinsOverConfigOverride() {
    let state = AppDirectories.stateDirectory(
      home: Self.home, override: "/tmp/codans-state", configOverride: "/tmp/codans-config")
    #expect(state.path == "/tmp/codans-state")
  }

  @Test
  func legacyDirectoryIsTheOldConfigRoot() {
    #expect(AppDirectories.legacyConfigDirectory(home: Self.home).path == "/tmp/fake-home/.config/\(AppDirectories.name)")
  }
}
