import Foundation
import Testing
import CodansCore

/// `$CODANS_CONFIG_DIR` / `$CODANS_STATE_DIR` isolation seams and the
/// `~/.codans[-dev]/{config,state}` defaults (`AppDirectories`).
/// Relocating the roots is what lets an end-to-end smoke run drive a real
/// Debug app + CLI without mutating the user's real `~/.codans/`.
struct AppDirectoriesConfigOverrideTests {
  private static let home = URL(fileURLWithPath: "/tmp/fake-home")
  /// `~/.codans` for Release test runs, `~/.codans-dev` for Debug.
  private static let root = "/tmp/fake-home/.\(AppDirectories.name)"

  @Test
  func overrideRelocatesConfigRootEntirely() {
    let url = AppDirectories.configDirectory(home: Self.home, override: "/tmp/codans-iso-123")
    #expect(url.path == "/tmp/codans-iso-123")
  }

  @Test
  func nilOverrideFallsBackToTheChannelRoot() {
    let url = AppDirectories.configDirectory(home: Self.home, override: nil)
    #expect(url.path == "\(Self.root)/config")
  }

  @Test
  func emptyOverrideFallsBackToTheChannelRoot() {
    let url = AppDirectories.configDirectory(home: Self.home, override: "")
    #expect(url.path == "\(Self.root)/config")
  }

  @Test
  func stateDefaultsToASiblingOfConfigUnderTheChannelRoot() {
    let url = AppDirectories.stateDirectory(home: Self.home, override: nil, configOverride: nil)
    #expect(url.path == "\(Self.root)/state")
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
  func channelsAreIsolatedAtTheTopLevel() {
    #expect(AppDirectories.channelDirectory(home: Self.home).path == Self.root)
  }

  @Test
  func legacyDirectoryIsTheOldConfigRoot() {
    #expect(AppDirectories.legacyConfigDirectory(home: Self.home).path == "/tmp/fake-home/.config/\(AppDirectories.name)")
  }
}
