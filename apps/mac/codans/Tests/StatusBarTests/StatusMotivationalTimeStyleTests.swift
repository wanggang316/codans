import SwiftUI
import Testing

@testable import Codans

/// Time-of-day → (icon, colour) mapping for `StatusMotivationalView`.
/// Pure function, so we don't spin up SwiftUI.
@MainActor
struct StatusMotivationalTimeStyleTests {
  @Test
  func sixAmIsSunrise() {
    let s = StatusMotivationalView.timeStyle(for: 6)
    #expect(s.icon == "sunrise.fill")
  }

  @Test
  func fiveAmIsNight() {
    let s = StatusMotivationalView.timeStyle(for: 5)
    #expect(s.icon == "moon.stars.fill")
  }

  @Test
  func noonIsDaytime() {
    let s = StatusMotivationalView.timeStyle(for: 12)
    #expect(s.icon == "sun.max.fill")
  }

  @Test
  func elevenIsStillSunrise() {
    let s = StatusMotivationalView.timeStyle(for: 11)
    #expect(s.icon == "sunrise.fill")
  }

  @Test
  func sixteenIsStillDaytime() {
    let s = StatusMotivationalView.timeStyle(for: 16)
    #expect(s.icon == "sun.max.fill")
  }

  @Test
  func seventeenIsSunset() {
    let s = StatusMotivationalView.timeStyle(for: 17)
    #expect(s.icon == "sunset.fill")
  }

  @Test
  func twentyOneIsNight() {
    let s = StatusMotivationalView.timeStyle(for: 21)
    #expect(s.icon == "moon.stars.fill")
  }

  @Test
  func midnightIsNight() {
    let s = StatusMotivationalView.timeStyle(for: 0)
    #expect(s.icon == "moon.stars.fill")
  }
}
