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

  /// `host` or `host:port`, with no scheme, user, path, or white space. A bracketed IPv6
  /// literal is accepted.
  public static func isValidHost(_ host: String) -> Bool {
    guard !host.isEmpty else { return false }
    return host.allSatisfy { char in
      char.isASCII && (char.isLetter || char.isNumber || ".-_:[]".contains(char))
    }
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
