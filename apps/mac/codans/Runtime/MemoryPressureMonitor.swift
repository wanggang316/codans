import Dispatch
import notify

/// Level of a system memory-pressure event the app reacts to.
nonisolated enum MemoryPressureLevel: String, Sendable {
  case warning
  case critical
}

/// Delivers the process's memory-pressure events (`.warning`, `.critical`)
/// on the main actor. A `.normal` event means pressure ended; nothing to do.
@MainActor
final class MemoryPressureMonitor {
  private let source: DispatchSourceMemoryPressure
  private let onPressure: @MainActor (MemoryPressureLevel) -> Void
  #if DEBUG
    /// Debug builds also take a simulated `.warning` event from
    /// `notifyutil -p <simulatedPressureNotification>`. `memory_pressure -S`
    /// needs root, which makes before/after measurements awkward.
    static let simulatedPressureNotification = "dev.codans.debug.memory-pressure"
    private var simulationToken: Int32 = NOTIFY_TOKEN_INVALID
  #endif

  init(onPressure: @escaping @MainActor (MemoryPressureLevel) -> Void) {
    self.onPressure = onPressure
    source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
  }

  // Nonisolated for the same reason as `TerminalEngine.deinit`.
  deinit {
    source.cancel()
    #if DEBUG
      if simulationToken != NOTIFY_TOKEN_INVALID { notify_cancel(simulationToken) }
    #endif
  }

  func start() {
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        let event = self.source.data
        if event.contains(.critical) {
          self.onPressure(.critical)
        } else if event.contains(.warning) {
          self.onPressure(.warning)
        }
      }
    }
    source.activate()
    #if DEBUG
      notify_register_dispatch(Self.simulatedPressureNotification, &simulationToken, .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.onPressure(.warning) }
      }
    #endif
  }

  func cancel() {
    source.cancel()
    #if DEBUG
      if simulationToken != NOTIFY_TOKEN_INVALID {
        notify_cancel(simulationToken)
        simulationToken = NOTIFY_TOKEN_INVALID
      }
    #endif
  }
}
