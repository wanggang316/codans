import Foundation
import Testing
import CodansCore

@testable import Codans

@MainActor
struct ShortcutsStoreTests {
  @Test
  func emptyFileLoadsEmptyOverrides() {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    #expect(store.overrides.overrides.isEmpty)
    #expect(store.resolved.count == CommandID.allCases.count)
  }

  @Test
  func updateThenSaveNowPersistsOverride() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    let custom = ShortcutBinding(keyCode: 17, modifiers: [.command, .control])
    store.update(.newTab, to: custom)
    try store.saveNow()

    let reread = try AtomicFileStore.read(ShortcutOverrideStore.self, at: url)
    #expect(reread?.overrides[.newTab] == custom)
  }

  @Test
  func roundTripAcrossInstances() async throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    // Distinct from the schema default `⌘⇧G` so the coalescing path doesn't drop it.
    let custom = ShortcutBinding(keyCode: 5, modifiers: [.command, .control])
    let writer = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    writer.update(.toggleDiffInspector, to: custom)
    writer.flush()

    let reader = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    #expect(reader.overrides.overrides[.toggleDiffInspector] == custom)
    #expect(reader.resolved[.toggleDiffInspector]?.binding == custom)
    #expect(reader.resolved[.toggleDiffInspector]?.source == .userOverride)
  }

  @Test
  func updateWithSchemaDefaultBindingDropsOverride() {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    let custom = ShortcutBinding(keyCode: 99, modifiers: [.command, .control])
    store.update(.toggleDiffInspector, to: custom)
    #expect(store.overrides.overrides[.toggleDiffInspector] == custom)

    let schemaDefault = ShortcutSchema.app.entry(for: .toggleDiffInspector)!.defaultBinding!
    store.update(.toggleDiffInspector, to: schemaDefault)

    #expect(store.overrides.overrides[.toggleDiffInspector] == nil)
    #expect(store.resolved[.toggleDiffInspector]?.source == .schemaDefault)
  }

  @Test
  func resolveConflictDisablesOldRowAndAssignsTarget() {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    let conflicting = ShortcutBinding(keyCode: 17, modifiers: [.command])  // ⌘T equivalent
    store.resolveConflict(disabling: .newTab, assigning: .toggleDiffInspector, to: conflicting)

    #expect(store.resolved[.newTab]?.isEnabled == false)
    #expect(store.resolved[.newTab]?.source == .userOverride)
    #expect(store.resolved[.toggleDiffInspector]?.binding == conflicting)
    #expect(store.resolved[.toggleDiffInspector]?.isEnabled == true)
    #expect(store.resolved[.toggleDiffInspector]?.source == .userOverride)
  }

  @Test
  func disablePreservesBindingButFlipsEnabledFlag() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    store.disable(.toggleDiffInspector)
    try store.saveNow()

    let entry = store.overrides.overrides[.toggleDiffInspector]
    let schemaDefault = ShortcutSchema.app.entry(for: .toggleDiffInspector)?.defaultBinding
    #expect(entry?.keyCode == schemaDefault?.keyCode)
    #expect(entry?.modifiers == schemaDefault?.modifiers)
    #expect(entry?.isEnabled == false)

    #expect(store.resolved[.toggleDiffInspector]?.isEnabled == false)
  }

  @Test
  func clearRevertsToSchemaDefault() {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    store.update(.newTab, to: .init(keyCode: 99, modifiers: .command))
    store.clear(.newTab)

    #expect(store.overrides.overrides[.newTab] == nil)
    let schemaDefault = ShortcutSchema.app.entry(for: .newTab)?.defaultBinding
    #expect(store.resolved[.newTab]?.binding == schemaDefault)
    #expect(store.resolved[.newTab]?.source == .schemaDefault)
  }

  @Test
  func resetAllDropsEveryOverride() {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    store.update(.newTab, to: .init(keyCode: 17, modifiers: .command))
    store.update(.toggleDiffInspector, to: .init(keyCode: 5, modifiers: .command))
    store.resetAll()

    #expect(store.overrides.overrides.isEmpty)
  }

  @Test
  func brokenFileIsBackedUpAndStoreStartsEmpty() throws {
    let url = Self.temporaryURL()
    defer {
      try? FileManager.default.removeItem(at: url)
      try? Self.cleanUpBackups(siblingOf: url)
    }

    try Data("not json".utf8).write(to: url)

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    #expect(store.overrides.overrides.isEmpty)

    let backups = Self.findBackups(siblingOf: url)
    #expect(!backups.isEmpty, "Expected a `shortcuts.json.broken-*` backup beside the canonical URL.")
  }

  @Test
  func unsupportedVersionIsBackedUp() throws {
    let url = Self.temporaryURL()
    defer {
      try? FileManager.default.removeItem(at: url)
      try? Self.cleanUpBackups(siblingOf: url)
    }

    let payload = Data(#"{"version": 99, "overrides": {}}"#.utf8)
    try payload.write(to: url)

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    #expect(store.overrides.overrides.isEmpty)

    let backups = Self.findBackups(siblingOf: url)
    #expect(!backups.isEmpty)
  }

  @Test
  func debounceCoalescesBurstIntoOneWrite() async throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(80))

    store.update(.newTab, to: .init(keyCode: 1, modifiers: .command))
    store.update(.newTab, to: .init(keyCode: 2, modifiers: .command))
    let final = ShortcutBinding(keyCode: 3, modifiers: .command)
    store.update(.newTab, to: final)

    // File should not exist yet — all three writes are pending behind one debounce window.
    #expect(!FileManager.default.fileExists(atPath: url.path))

    try await Task.sleep(for: .milliseconds(200))

    let reread = try AtomicFileStore.read(ShortcutOverrideStore.self, at: url)
    #expect(reread?.overrides[.newTab] == final, "Last mutation should win after debounce.")
  }

  @Test
  func defaultURLPointsAtConfigDirectory() {
    let home = URL(fileURLWithPath: "/tmp/fake-home", isDirectory: true)
    let url = ShortcutsStore.defaultURL(home: home)
    // Build-type aware: Debug test runs resolve `AppDirectories.name` to
    // `codans-dev`, Release to `codans` — assert against the same
    // source of truth rather than a hardcoded segment.
    #expect(url.path == "/tmp/fake-home/.config/\(AppDirectories.name)/shortcuts.json")
  }

  // MARK: - Test helpers

  private static func temporaryURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("shortcuts-store-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("shortcuts.json", isDirectory: false)
  }

  private static func findBackups(siblingOf url: URL) -> [URL] {
    let directory = url.deletingLastPathComponent()
    let prefix = "\(url.lastPathComponent).broken-"
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return
      entries
      .filter { $0.hasPrefix(prefix) }
      .map { directory.appendingPathComponent($0) }
  }

  private static func cleanUpBackups(siblingOf url: URL) throws {
    for backup in findBackups(siblingOf: url) {
      try? FileManager.default.removeItem(at: backup)
    }
  }
}
