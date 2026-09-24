import CodansRemote
import Foundation
import Network
import dnssd
import os

/// Finds the endpoint of a paired gateway with `NWBrowser`. Only services
/// whose TXT `channel` equals the pairing's channel are considered, so a
/// phone paired with the Release build never reaches a Debug build on the
/// same Mac. The exact service name wins; when the Mac was renamed since
/// pairing, a single same-channel gateway is used instead.
nonisolated enum GatewayDiscovery {
  static let defaultTimeout: Duration = .seconds(8)

  static func resolve(_ gateway: PairedGateway, timeout: Duration = defaultTimeout) async throws -> NWEndpoint {
    let browser = NWBrowser(
      for: .bonjourWithTXTRecord(type: RemoteBonjour.serviceType, domain: nil),
      using: NWParameters()
    )
    let queue = DispatchQueue(label: "com.gumpw.codans.mobile.discovery")
    defer { browser.cancel() }

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint, Error>) in
      let pending = OSAllocatedUnfairLock<CheckedContinuation<NWEndpoint, Error>?>(initialState: continuation)
      let finish: @Sendable (Result<NWEndpoint, Error>) -> Void = { result in
        pending.withLock { slot -> CheckedContinuation<NWEndpoint, Error>? in
          defer { slot = nil }
          return slot
        }?.resume(with: result)
      }

      browser.browseResultsChangedHandler = { results, _ in
        if let endpoint = match(gateway, in: results) {
          finish(.success(endpoint))
        }
      }
      browser.stateUpdateHandler = { state in
        switch state {
        case .failed(let error):
          finish(.failure(failure(for: error)))
        case .waiting(let error) where isPolicyDenied(error):
          finish(.failure(failure(for: error)))
        default:
          break
        }
      }
      browser.start(queue: queue)

      Task {
        try? await Task.sleep(for: timeout)
        finish(
          .failure(
            RemoteFailure(
              .notFound,
              "Couldn't find \(gateway.displayName) on this network. Check that Remote Access is on and both devices share a network."
            )))
      }
    }
  }

  /// The endpoint to connect to among `results`, if any qualifies.
  static func match(_ gateway: PairedGateway, in results: Set<NWBrowser.Result>) -> NWEndpoint? {
    let sameChannel = results.filter { result in
      guard case .bonjour(let record) = result.metadata else { return false }
      return RemoteBonjour.channel(in: record) == gateway.channel
    }
    if let exact = sameChannel.first(where: { serviceName(of: $0.endpoint) == gateway.serviceName }) {
      return exact.endpoint
    }
    return sameChannel.count == 1 ? sameChannel.first?.endpoint : nil
  }

  private static func serviceName(of endpoint: NWEndpoint) -> String? {
    if case .service(let name, _, _, _) = endpoint { return name }
    return nil
  }

  private static func isPolicyDenied(_ error: NWError) -> Bool {
    if case .dns(let code) = error { return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) }
    return false
  }

  private static func failure(for error: NWError) -> RemoteFailure {
    if isPolicyDenied(error) {
      return RemoteFailure(
        .localNetworkDenied,
        "Codans needs Local Network access to reach your Mac. Turn it on in Settings › Privacy & Security › Local Network."
      )
    }
    return RemoteFailure(.other, "Browsing the local network failed: \(error.localizedDescription)")
  }
}
