import Observation
import Testing

@testable import Codans

/// A view that re-renders synchronously from the change notification must read the new
/// state. Observation sends that notification before a stored property changes, so a reader
/// in it would render the old state and keep it until the next change.
@MainActor
struct CommandKeyObserverTests {
  @Test(arguments: [true, false])
  func changeNotificationReadsTheNewState(held: Bool) {
    let observer = CommandKeyObserver()
    if !held {
      observer.setCommandHeld(true)
    }
    let seen = SeenState()
    withObservationTracking {
      _ = observer.isCommandHeld
    } onChange: {
      MainActor.assumeIsolated { seen.value = observer.isCommandHeld }
    }

    observer.setCommandHeld(held)

    #expect(seen.value == held)
  }

  @Test(arguments: [true, false])
  func commandOptionChangeNotificationReadsTheNewState(held: Bool) {
    let observer = CommandKeyObserver()
    if !held {
      observer.setCommandOptionHeld(true)
    }
    let seen = SeenState()
    withObservationTracking {
      _ = observer.isCommandOptionHeld
    } onChange: {
      MainActor.assumeIsolated { seen.value = observer.isCommandOptionHeld }
    }

    observer.setCommandOptionHeld(held)

    #expect(seen.value == held)
    #expect(!observer.isCommandHeld)
  }
}

@MainActor
private final class SeenState {
  var value: Bool?
}
