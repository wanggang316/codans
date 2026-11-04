import Foundation

/// Maps a remote host, as it appears in an `origin` URL, to a Code Host kind and the API
/// host that kind's CLI uses. One alias applies to every Project and Workspace member whose
/// `origin` has that host. The resolver checks aliases before any other step. See ADR 0005.
///
/// Example: `ssh.gitlab.example.com` → GitLab, `gitlab.example.com`.
///
/// Hosts are stored trimmed and lowercased, so a lookup compares them as they are.
public nonisolated struct CodeHostAlias: Equatable, Hashable, Codable, Sendable, Identifiable {
  public var id: UUID
  /// Host of the `origin` URL. It can carry a port; an SSH remote also matches it without
  /// its SSH port.
  public var remoteHost: String
  public var kind: CodeHostKind
  /// Host the CLI of `kind` is logged in to, with its port when it has one.
  public var apiHost: String

  public init(id: UUID = UUID(), remoteHost: String, kind: CodeHostKind, apiHost: String) {
    self.id = id
    self.remoteHost = Self.normalizedHost(remoteHost)
    self.kind = kind
    self.apiHost = Self.normalizedHost(apiHost)
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
      remoteHost: try c.decode(String.self, forKey: .remoteHost),
      kind: try c.decode(CodeHostKind.self, forKey: .kind),
      apiHost: try c.decode(String.self, forKey: .apiHost))
  }

  public static func normalizedHost(_ host: String) -> String {
    host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// `name[:port]` or `[IPv6][:port]`, with no scheme, user, path, or white space. A name
  /// is dot-separated labels of letters, digits, `-`, and `_`; a port is 1–65535. The API
  /// host becomes part of an API URL, so a host that cannot form one is refused.
  public static func isValidHost(_ host: String) -> Bool {
    let port: Substring?
    if host.hasPrefix("[") {
      guard let close = host.firstIndex(of: "]") else { return false }
      let literal = host[host.index(after: host.startIndex)..<close]
      guard literal.contains(":"), literal.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else {
        return false
      }
      let rest = host[host.index(after: close)...]
      guard rest.isEmpty || rest.hasPrefix(":") else { return false }
      port = rest.isEmpty ? nil : rest.dropFirst()
    } else {
      let parts = host.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count <= 2 else { return false }
      let name = parts[0]
      port = parts.count == 2 ? parts[1] : nil
      let labels = name.split(separator: ".", omittingEmptySubsequences: false)
      guard !name.isEmpty,
        labels.allSatisfy({ label in
          !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        })
      else { return false }
    }
    guard let port else { return true }
    guard !port.isEmpty, port.count <= 5, port.allSatisfy(\.isASCII), let number = Int(port) else { return false }
    return (1...65535).contains(number)
  }
}

/// Why a Code Host alias cannot be saved.
public nonisolated enum CodeHostAliasError: Error, Equatable, Sendable {
  case invalidRemoteHost
  case invalidAPIHost
  /// Another alias has the same remote host.
  case duplicateRemoteHost(String)

  public var message: String {
    switch self {
    case .invalidRemoteHost: return "Enter the host of the origin URL, for example ssh.gitlab.example.com."
    case .invalidAPIHost: return "Enter the API host, for example gitlab.example.com or 192.168.2.158:8929."
    case .duplicateRemoteHost(let host): return "An alias for \(host) already exists."
    }
  }
}

extension GeneralSettings {
  /// Adds `alias`, or replaces the alias with the same id. Throws when a host is not
  /// valid or another alias has the same remote host; the list is then unchanged.
  public mutating func saveCodeHostAlias(_ alias: CodeHostAlias) throws(CodeHostAliasError) {
    let alias = CodeHostAlias(id: alias.id, remoteHost: alias.remoteHost, kind: alias.kind, apiHost: alias.apiHost)
    guard CodeHostAlias.isValidHost(alias.remoteHost) else { throw .invalidRemoteHost }
    guard CodeHostAlias.isValidHost(alias.apiHost) else { throw .invalidAPIHost }
    if codeHostAliases.contains(where: { $0.id != alias.id && $0.remoteHost == alias.remoteHost }) {
      throw .duplicateRemoteHost(alias.remoteHost)
    }
    if let index = codeHostAliases.firstIndex(where: { $0.id == alias.id }) {
      codeHostAliases[index] = alias
    } else {
      codeHostAliases.append(alias)
    }
  }

  public mutating func removeCodeHostAlias(id: CodeHostAlias.ID) {
    codeHostAliases.removeAll { $0.id == id }
  }
}
