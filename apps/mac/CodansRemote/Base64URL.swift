import Foundation

extension Data {
  /// RFC 4648 §5 base64url without padding — safe in URLs and QR codes
  /// without escaping.
  func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// Inverse of `base64URLEncodedString()`. Accepts input with or without
  /// padding; returns nil for anything that is not base64url.
  init?(base64URLEncoded string: String) {
    var base64 =
      string
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder == 1 { return nil }
    if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
    guard !string.contains(where: { $0 == "+" || $0 == "/" }),
      let data = Data(base64Encoded: base64)
    else { return nil }
    self = data
  }
}
