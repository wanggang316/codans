import ComposableArchitecture
import Foundation
import Network

/// Reports when the device regains a usable network path, so a connection
/// waiting out its backoff can retry immediately instead of sleeping on.
nonisolated struct NetworkPathClient: Sendable {
  /// Yields each time the path becomes satisfied after not being so.
  var becameAvailable: @Sendable () -> AsyncStream<Void>
}

nonisolated extension NetworkPathClient: DependencyKey {
  static let liveValue = NetworkPathClient(
    becameAvailable: {
      AsyncStream { continuation in
        let monitor = NWPathMonitor()
        let wasSatisfied = LockIsolated<Bool?>(nil)
        monitor.pathUpdateHandler = { path in
          let satisfied = path.status == .satisfied
          let previous = wasSatisfied.withValue { value -> Bool? in
            defer { value = satisfied }
            return value
          }
          if satisfied, previous == false { continuation.yield() }
        }
        continuation.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "com.gumpw.codans.mobile.path"))
      }
    }
  )

  static let testValue = NetworkPathClient(
    becameAvailable: unimplemented("NetworkPathClient.becameAvailable", placeholder: .finished)
  )
}

nonisolated extension DependencyValues {
  var networkPath: NetworkPathClient {
    get { self[NetworkPathClient.self] }
    set { self[NetworkPathClient.self] = newValue }
  }
}
