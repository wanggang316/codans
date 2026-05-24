import AppKit
import SwiftUI
import Testing
import TouchCodeCore

@testable import TouchCode

struct AppearancePreferenceUITests {
  @Test
  func colorSchemeMapping() {
    #expect(AppearancePreference.system.colorScheme == nil)
    #expect(AppearancePreference.light.colorScheme == .light)
    #expect(AppearancePreference.dark.colorScheme == .dark)
  }

  @Test
  func appearanceMapping() {
    #expect(AppearancePreference.system.appearance == nil)
    #expect(AppearancePreference.light.appearance?.name == NSAppearance.Name.aqua)
    #expect(AppearancePreference.dark.appearance?.name == NSAppearance.Name.darkAqua)
  }
}
