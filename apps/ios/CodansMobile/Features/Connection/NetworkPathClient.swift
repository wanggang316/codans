import ComposableArchitecture
import Foundation
import Network

/// Reports changes of the device's network path, so the connection can
/// reconnect at once instead of waiting out a backoff or a dead socket: a
/// Wi-Fi hand-off or a switch of interface leaves the old connection
/// half-open, and TCP alone takes minutes to notice.
nonisolated struct NetworkPathClient: Sendable {
  /// What the connection cares about in an `NWPath`.
  struct Path: Equatable, Sendable {
    var isSatisfied: Bool
    /// The available interfaces, as "type:name", in path order. A change
    /// here with the path still satisfied is a hand-off.
    var interfaces: [String]
  }

  /// Yields each path that differs from the one before it. The path
  /// current when iteration starts is the baseline and is not yielded.
  var changes: @Sendable () -> AsyncStream<Path>
}

nonisolated extension NetworkPathClient: DependencyKey {
  static let liveValue = NetworkPathClient(
    changes: {
      AsyncStream { continuation in
        let monitor = NWPathMonitor()
        let previous = LockIsolated<Path?>(nil)
        monitor.pathUpdateHandler = { nwPath in
          let path = Path(
            isSatisfied: nwPath.status == .satisfied,
            interfaces: nwPath.availableInterfaces.map { "\($0.type):\($0.name)" }
          )
          // NWPathMonitor repeats unchanged paths; only a real change is
          // worth a reconnect.
          let last = previous.withValue { value -> Path? in
            defer { value = path }
            return value
          }
          if let last, last != path { continuation.yield(path) }
        }
        continuation.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "com.gumpw.codans.mobile.path"))
      }
    }
  )

  static let testValue = NetworkPathClient(
    changes: unimplemented("NetworkPathClient.changes", placeholder: .finished)
  )
}

nonisolated extension DependencyValues {
  var networkPath: NetworkPathClient {
    get { self[NetworkPathClient.self] }
    set { self[NetworkPathClient.self] = newValue }
  }
}
