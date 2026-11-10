import Foundation
import Network
import dnssd
import os

extension RemoteBonjour {
  public enum ResolveError: Error, Equatable, Sendable {
    case timedOut
    /// DNS-SD reported an error, e.g. `kDNSServiceErr_PolicyDenied` without
    /// Local Network access.
    case failed(DNSServiceErrorType)
  }

  /// Resolves a Bonjour `.service` endpoint to the host name and port it
  /// advertises; any other endpoint is returned as-is.
  ///
  /// A TLS connection must not be opened to the `.service` endpoint
  /// itself: its mDNS resolver keeps waiting for more answers, so when the
  /// peer fails the handshake the connection stays `.preparing` instead of
  /// reporting the failure, and a refused PSK looks like a Mac that never
  /// answered. A `.hostPort` connection reports the refusal at once.
  public static func resolve(_ endpoint: NWEndpoint, timeout: Duration) async throws -> NWEndpoint {
    guard case .service(let name, let type, let domain, _) = endpoint else { return endpoint }
    let request = ResolveRequest()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        request.start(name: name, type: type, domain: domain, timeout: timeout, continuation: continuation)
      }
    } onCancel: {
      request.cancel()
    }
  }
}

/// One `DNSServiceResolve` call. Every field is touched only on `queue`,
/// which is also where DNS-SD delivers the reply, so the reference is
/// deallocated before any later callback could reach a finished request.
private final class ResolveRequest: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.gumpw.codans.remote.resolve")
  private var ref: DNSServiceRef?
  private var continuation: CheckedContinuation<NWEndpoint, Error>?
  private var isCancelled = false

  func start(
    name: String, type: String, domain: String, timeout: Duration,
    continuation: CheckedContinuation<NWEndpoint, Error>
  ) {
    queue.async { [self] in
      self.continuation = continuation
      guard !isCancelled else { return finish(.failure(CancellationError())) }
      let context = Unmanaged.passUnretained(self).toOpaque()
      let status = DNSServiceResolve(
        &ref, 0, 0, name, type, domain.isEmpty ? "local." : domain,
        { _, _, _, error, _, hostTarget, port, _, _, context in
          guard let context else { return }
          let request = Unmanaged<ResolveRequest>.fromOpaque(context).takeUnretainedValue()
          guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let hostTarget,
            let port = NWEndpoint.Port(rawValue: UInt16(bigEndian: port))
          else {
            request.finish(.failure(RemoteBonjour.ResolveError.failed(error)))
            return
          }
          request.finish(.success(.hostPort(host: NWEndpoint.Host(String(cString: hostTarget)), port: port)))
        }, context)
      guard status == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
        return finish(.failure(RemoteBonjour.ResolveError.failed(status)))
      }
      DNSServiceSetDispatchQueue(ref, queue)
      queue.asyncAfter(deadline: .now() + timeout.timeInterval) { [self] in
        finish(.failure(RemoteBonjour.ResolveError.timedOut))
      }
    }
  }

  func cancel() {
    queue.async { [self] in
      isCancelled = true
      finish(.failure(CancellationError()))
    }
  }

  private func finish(_ result: Result<NWEndpoint, Error>) {
    if let ref {
      DNSServiceRefDeallocate(ref)
      self.ref = nil
    }
    continuation?.resume(with: result)
    continuation = nil
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}
