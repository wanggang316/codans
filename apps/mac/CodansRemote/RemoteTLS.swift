import Foundation
import Network
import Security

/// TLS-PSK parameters for the LAN gateway. Both ends pin TLS 1.2 and one
/// PSK cipher suite; a peer without the right key cannot complete the
/// handshake, so an unpaired device never reaches the IPC layer.
public enum RemoteTLS {
  /// `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (RFC 7905): an ephemeral
  /// ECDHE exchange for forward secrecy, authenticated by the PSK, with an
  /// AEAD record cipher. The SDK exposes no ECDHE_PSK AES-GCM suite, and
  /// plain `PSK_WITH_AES_128_GCM` lacks forward secrecy.
  public static let cipherSuite = tls_ciphersuite_t(
    rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!

  /// Label for the RFC 5705 keying-material exporter that binds the
  /// application-level peer proof to this TLS session.
  static let channelBindingLabel = "EXPORTER-codans-remote-peer-proof"
  static let channelBindingLength = 32

  /// One pre-shared key and the identity it is offered under.
  public struct PSKCredential: Equatable, Hashable, Sendable {
    public let identity: String
    public let key: Data

    public init(identity: String, key: Data) {
      self.identity = identity
      self.key = key
    }
  }

  /// Client parameters: offers exactly one credential.
  public static func clientParameters(credential: PSKCredential) -> NWParameters {
    parameters(credentials: [credential])
  }

  /// Server parameters: every currently paired credential. The TLS stack
  /// picks the key whose identity the client offers; an identity that is
  /// not in the list fails the handshake ("unknown PSK identity").
  ///
  /// Network.framework gives the server no per-connection key lookup and
  /// does not report which identity was negotiated, so (a) the gateway
  /// rebuilds its listener whenever the paired set changes, and (b) the
  /// device identity is established by `RemotePeerProof` right after the
  /// handshake. `credentials` must not be empty — a listener with no keys
  /// has nobody to serve.
  public static func serverParameters(credentials: [PSKCredential]) -> NWParameters {
    precondition(!credentials.isEmpty, "a TLS-PSK server needs at least one credential")
    let parameters = parameters(credentials: credentials)
    // LAN only: never serve over a cellular interface.
    parameters.prohibitedInterfaceTypes = [.cellular]
    return parameters
  }

  private static func parameters(credentials: [PSKCredential]) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    for credential in credentials {
      sec_protocol_options_add_pre_shared_key(
        options,
        dispatchData(credential.key),
        dispatchData(Data(credential.identity.utf8))
      )
    }
    sec_protocol_options_append_tls_ciphersuite(options, cipherSuite)
    // External-PSK support in Network.framework covers the TLS 1.2 suites.
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

    let tcp = NWProtocolTCP.Options()
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 30
    return NWParameters(tls: tls, tcp: tcp)
  }

  /// RFC 5705 exporter output for an established TLS connection. Both ends
  /// derive the same bytes, and nobody outside the session can. Nil before
  /// the handshake completes.
  public static func channelBinding(of connection: NWConnection) -> Data? {
    guard
      let metadata = connection.metadata(definition: NWProtocolTLS.definition)
        as? NWProtocolTLS.Metadata
    else { return nil }
    let secret = channelBindingLabel.withCString { label in
      sec_protocol_metadata_create_secret(
        metadata.securityProtocolMetadata,
        channelBindingLabel.utf8.count,
        label,
        channelBindingLength
      )
    }
    return secret.map { Data($0 as DispatchData) }
  }

  /// The cipher suite the connection negotiated, for diagnostics and tests.
  public static func negotiatedCipherSuite(of connection: NWConnection) -> tls_ciphersuite_t? {
    guard
      let metadata = connection.metadata(definition: NWProtocolTLS.definition)
        as? NWProtocolTLS.Metadata
    else { return nil }
    return sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata)
  }

  static func dispatchData(_ data: Data) -> __DispatchData {
    data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
  }
}
