import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

@MainActor
struct SettingsTerminalFeatureTests {
  private func makeSnapshot(
    light: String? = "Light A",
    dark: String? = "Dark A",
    cursorStyle: GhosttyCursorStyle? = nil,
    fontFamily: String? = nil,
    fontSize: Double? = nil,
    warning: String? = nil
  ) -> GhosttyTerminalSettings {
    GhosttyTerminalSettings(
      configPath: "/tmp/ghostty/config",
      lightTheme: light,
      darkTheme: dark,
      cursorStyle: cursorStyle,
      fontFamily: fontFamily,
      fontSize: fontSize,
      availableLightThemes: ["Light A", "Light B"],
      availableDarkThemes: ["Dark A", "Dark B"],
      availableFontFamilies: ["Helvetica", "Menlo", "Fira Code"],
      monospacedFontFamilies: ["Menlo", "Fira Code"],
      themePreviews: [:],
      warningMessage: warning
    )
  }

  @Test
  func onAppearLoadsSnapshot() async {
    let loaded = makeSnapshot(warning: "non-split theme")
    let store = TestStore(initialState: SettingsTerminalFeature.State()) {
      SettingsTerminalFeature()
    } withDependencies: {
      $0[GhosttyTerminalSettingsClient.self] = GhosttyTerminalSettingsClient(
        load: { loaded },
        apply: { _ in loaded }
      )
    }
    await store.send(.onAppear) { $0.isLoading = true }
    await store.receive(\.loadResult.success) {
      $0.isLoading = false
      $0.snapshot = loaded
      $0.warningMessage = "non-split theme"
    }
  }

  @Test
  func onAppearIsIdempotentOnceLoaded() async {
    let preloaded = makeSnapshot()
    let store = TestStore(
      initialState: makeState(snapshot: preloaded)
    ) {
      SettingsTerminalFeature()
    } withDependencies: {
      $0[GhosttyTerminalSettingsClient.self] = GhosttyTerminalSettingsClient(
        load: {
          Issue.record("load should not be called")
          return preloaded
        },
        apply: { _ in preloaded }
      )
    }
    // Guard `snapshot != nil` short-circuits — no state change, no effect.
    await store.send(.onAppear)
  }

  @Test
  func lightThemePickAppliesAndUpdatesSnapshot() async {
    let initial = makeSnapshot(light: "Light A", dark: "Dark A")
    let applied = makeSnapshot(light: "Light B", dark: "Dark A")
    let store = TestStore(
      initialState: makeState(snapshot: initial)
    ) {
      SettingsTerminalFeature()
    } withDependencies: {
      $0[GhosttyTerminalSettingsClient.self] = GhosttyTerminalSettingsClient(
        load: { initial },
        apply: { draft in
          #expect(draft.lightTheme == "Light B")
          #expect(draft.darkTheme == "Dark A")
          return applied
        }
      )
    }
    await store.send(.lightThemeSelected("Light B")) { $0.isApplying = true }
    await store.receive(\.applyResult.success) {
      $0.isApplying = false
      $0.snapshot = applied
    }
  }

  @Test
  func cursorStylePickCarriesThemesAndApplies() async {
    let initial = makeSnapshot(light: "Light A", dark: "Dark A", cursorStyle: nil)
    let applied = makeSnapshot(light: "Light A", dark: "Dark A", cursorStyle: .bar)
    let store = TestStore(
      initialState: makeState(snapshot: initial)
    ) {
      SettingsTerminalFeature()
    } withDependencies: {
      $0[GhosttyTerminalSettingsClient.self] = GhosttyTerminalSettingsClient(
        load: { initial },
        apply: { draft in
          // The pick must carry the current themes forward, not drop them.
          #expect(draft.lightTheme == "Light A")
          #expect(draft.darkTheme == "Dark A")
          #expect(draft.cursorStyle == .bar)
          return applied
        }
      )
    }
    await store.send(.cursorStyleSelected(.bar)) { $0.isApplying = true }
    await store.receive(\.applyResult.success) {
      $0.isApplying = false
      $0.snapshot = applied
    }
  }

  @Test
  func fontFamilyPickCarriesOtherDirectivesForward() async {
    let initial = makeSnapshot(
      light: "Light A", dark: "Dark A", cursorStyle: .bar, fontFamily: nil, fontSize: 14
    )
    let applied = makeSnapshot(
      light: "Light A", dark: "Dark A", cursorStyle: .bar, fontFamily: "Fira Code", fontSize: 14
    )
    let store = TestStore(
      initialState: makeState(snapshot: initial)
    ) {
      SettingsTerminalFeature()
    } withDependencies: {
      $0[GhosttyTerminalSettingsClient.self] = GhosttyTerminalSettingsClient(
        load: { initial },
        apply: { draft in
          #expect(draft.fontFamily == "Fira Code")
          // Every other managed directive must ride along unchanged.
          #expect(draft.fontSize == 14)
          #expect(draft.cursorStyle == .bar)
          #expect(draft.lightTheme == "Light A")
          return applied
        }
      )
    }
    await store.send(.fontFamilySelected("Fira Code")) { $0.isApplying = true }
    await store.receive(\.applyResult.success) {
      $0.isApplying = false
      $0.snapshot = applied
    }
  }

  @Test
  func fontSizeSelectingDefaultClearsItButKeepsTheRest() async {
    // Selecting nil ("Default") must clear font-size — distinct from inheriting
    // the current value — while carrying the other directives forward.
    let initial = makeSnapshot(light: "Light A", dark: "Dark A", fontSize: 16)
    let applied = makeSnapshot(light: "Light A", dark: "Dark A", fontSize: nil)
    let store = TestStore(
      initialState: makeState(snapshot: initial)
    ) {
      SettingsTerminalFeature()
    } withDependencies: {
      $0[GhosttyTerminalSettingsClient.self] = GhosttyTerminalSettingsClient(
        load: { initial },
        apply: { draft in
          #expect(draft.fontSize == nil)
          #expect(draft.lightTheme == "Light A")
          return applied
        }
      )
    }
    await store.send(.fontSizeSelected(nil)) { $0.isApplying = true }
    await store.receive(\.applyResult.success) {
      $0.isApplying = false
      $0.snapshot = applied
    }
  }

  @Test
  func applyFailureSurfacesErrorMessage() async {
    let initial = makeSnapshot()
    struct Boom: LocalizedError { var errorDescription: String? { "Ghostty rejected config" } }
    let store = TestStore(
      initialState: makeState(snapshot: initial)
    ) {
      SettingsTerminalFeature()
    } withDependencies: {
      $0[GhosttyTerminalSettingsClient.self] = GhosttyTerminalSettingsClient(
        load: { initial },
        apply: { _ in throw Boom() }
      )
    }
    await store.send(.darkThemeSelected("Dark B")) { $0.isApplying = true }
    await store.receive(\.applyResult.failure) {
      $0.isApplying = false
      $0.errorMessage = "Ghostty rejected config"
    }
  }

  @Test
  func loadFailureSurfacesErrorMessage() async {
    struct Boom: LocalizedError { var errorDescription: String? { "unwired" } }
    let store = TestStore(initialState: SettingsTerminalFeature.State()) {
      SettingsTerminalFeature()
    } withDependencies: {
      $0[GhosttyTerminalSettingsClient.self] = GhosttyTerminalSettingsClient(
        load: { throw Boom() },
        apply: { _ in throw Boom() }
      )
    }
    await store.send(.onAppear) { $0.isLoading = true }
    await store.receive(\.loadResult.failure) {
      $0.isLoading = false
      $0.errorMessage = "unwired"
    }
  }
}

@MainActor
private func makeState(snapshot: GhosttyTerminalSettings) -> SettingsTerminalFeature.State {
  var state = SettingsTerminalFeature.State()
  state.snapshot = snapshot
  return state
}
