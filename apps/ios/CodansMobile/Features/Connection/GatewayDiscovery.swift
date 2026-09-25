import CodansRemote
import Foundation
import Network
import dnssd
import os

/// Finds the endpoints a paired gateway may be at, with `NWBrowser`. Only
/// services whose TXT `channel` equals the pairing's channel are
/// considered, so a phone paired with the Release build never reaches a
/// Debug build on the same Mac.
///
/// Several candidates are normal: after the Mac app crashes or is killed,
/// mDNS keeps its stale advertisement for up to an hour, and the relaunched
/// app registers under a renamed variant ("Name (2)"). The caller tries the
/// candidates in order until one connects.
nonisolated enum GatewayDiscovery {
  static let defaultTimeout: Duration = .seconds(8)
  /// After the first qualifying result, how long to keep browsing for the
  /// rest (a stale record and the live one arrive separately).
  static let settleDelay: DispatchTimeInterval = .milliseconds(750)

  /// One browse result, reduced to what matching needs.
  struct Offer: Equatable {
    let name: String?
    let channel: String?
    let endpoint: NWEndpoint
  }

  static func resolve(_ gateway: PairedGateway, timeout: Duration = defaultTimeout) async throws -> [NWEndpoint] {
    let browser = NWBrowser(
      for: .bonjourWithTXTRecord(type: RemoteBonjour.serviceType, domain: nil),
      using: NWParameters()
    )
    let queue = DispatchQueue(label: "com.gumpw.codans.mobile.discovery")
    defer { browser.cancel() }

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NWEndpoint], Error>) in
      let pending = OSAllocatedUnfairLock<CheckedContinuation<[NWEndpoint], Error>?>(initialState: continuation)
      let settling = OSAllocatedUnfairLock(initialState: false)
      let finish: @Sendable (Result<[NWEndpoint], Error>) -> Void = { result in
        pending.withLock { slot -> CheckedContinuation<[NWEndpoint], Error>? in
          defer { slot = nil }
          return slot
        }?.resume(with: result)
      }

      browser.browseResultsChangedHandler = { results, _ in
        guard !candidates(for: gateway, in: offers(results)).isEmpty else { return }
        // Keep collecting briefly, then answer with whatever is known.
        let isFirst = settling.withLock { started in
          let first = !started
          started = true
          return first
        }
        guard isFirst else { return }
        queue.asyncAfter(deadline: .now() + settleDelay) {
          finish(.success(candidates(for: gateway, in: offers(browser.browseResults))))
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

  /// Same-channel endpoints to try, best first: the paired service name,
  /// then names mDNS derived from it after a conflict ("Name (2)"), then,
  /// only when neither exists (the Mac was renamed), every other gateway on
  /// the channel. Ties are ordered by name so retries are stable.
  static func candidates(for gateway: PairedGateway, in offers: [Offer]) -> [NWEndpoint] {
    let sameChannel = offers.filter { $0.channel == gateway.channel }
      .sorted { ($0.name ?? "") < ($1.name ?? "") }
    let exact = sameChannel.filter { $0.name == gateway.serviceName }
    let renamed = sameChannel.filter { $0.name?.hasPrefix(gateway.serviceName + " (") == true }
    let preferred = exact + renamed
    return (preferred.isEmpty ? sameChannel : preferred).map(\.endpoint)
  }

  private static func offers(_ results: Set<NWBrowser.Result>) -> [Offer] {
    results.map { result in
      var channel: String?
      if case .bonjour(let record) = result.metadata { channel = RemoteBonjour.channel(in: record) }
      var name: String?
      if case .service(let serviceName, _, _, _) = result.endpoint { name = serviceName }
      return Offer(name: name, channel: channel, endpoint: result.endpoint)
    }
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
