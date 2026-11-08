import Foundation

/// The hosts `glab` is logged in to, read from its local `config.yml`. The resolver uses
/// them to recognise self-managed instances (ADR 0004 item 2). Reading the file needs no
/// network and no `glab` subprocess, so it works with every `glab` version, also one older
/// than `GitLab.minimumVersion`.
///
/// `glab` keeps one entry per host under the top-level `hosts:` key:
///
/// ```yaml
/// hosts:
///     192.168.2.158:8929:
///         token: glpat-…
///         api_protocol: http
/// ```
///
/// A host is logged in when it has a token, or when its token is in the keyring
/// (`use_keyring: true`). The reader is a small line parser for this one shape: `glab`
/// writes the file itself, and codans has no YAML dependency.
nonisolated enum GlabConfig {
  struct Host: Equatable, Sendable {
    var host: String
    /// `http` or `https`, as `api_protocol` in the file; `nil` when absent.
    var apiProtocol: String?
  }

  /// The logged-in hosts of the first `config.yml` found in `directories(environment:home:)`.
  /// Empty when no file exists or it cannot be read.
  static func loggedInHosts(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: String = NSHomeDirectory(),
  ) -> [Host] {
    for directory in directories(environment: environment, home: home) {
      let file = directory.appendingPathComponent("config.yml")
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
      return parseLoggedInHosts(text)
    }
    return []
  }

  /// Where `glab` keeps its config, in the order `glab` looks: `GLAB_CONFIG_DIR` only, when
  /// set; otherwise `$XDG_CONFIG_HOME/glab-cli`, `~/.config/glab-cli`, and the macOS
  /// location `~/Library/Application Support/glab-cli`.
  static func directories(environment: [String: String], home: String) -> [URL] {
    if let dir = environment["GLAB_CONFIG_DIR"], !dir.isEmpty {
      return [URL(fileURLWithPath: dir, isDirectory: true)]
    }
    let homeURL = URL(fileURLWithPath: home, isDirectory: true)
    var result: [URL] = []
    if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      result.append(URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("glab-cli"))
    }
    result.append(homeURL.appendingPathComponent(".config/glab-cli"))
    result.append(homeURL.appendingPathComponent("Library/Application Support/glab-cli"))
    return result
  }

  /// The logged-in hosts under `hosts:`, in file order. Any indentation width works: the
  /// first line under `hosts:` sets the host level, and the first deeper line of a host
  /// sets its field level. Deeper lines (lists, nested maps) are skipped.
  static func parseLoggedInHosts(_ text: String) -> [Host] {
    var hosts: [Host] = []
    var inHosts = false
    var hostIndent: Int?
    var fieldIndent: Int?
    var current: Entry?

    func flush() {
      guard let entry = current else { return }
      current = nil
      guard entry.hasToken || entry.usesKeyring else { return }
      hosts.append(Host(host: entry.name, apiProtocol: entry.apiProtocol))
    }

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      let indent = line.prefix { $0 == " " }.count
      if indent == 0 {
        flush()
        inHosts = trimmed == "hosts:"
        hostIndent = nil
        continue
      }
      guard inHosts else { continue }
      let level = hostIndent ?? indent
      hostIndent = level
      if indent == level {
        flush()
        fieldIndent = nil
        guard trimmed.hasSuffix(":") else { continue }
        current = Entry(name: unquoted(String(trimmed.dropLast())))
      } else if indent > level, current != nil {
        let fieldLevel = fieldIndent ?? indent
        fieldIndent = fieldLevel
        guard indent == fieldLevel, let (key, value) = field(trimmed) else { continue }
        current?.record(key: key, value: value)
      }
    }
    flush()
    return hosts
  }

  /// What the parser keeps of one host entry. Only whether a token is set, never its
  /// value: codans does not hold `glab` tokens.
  private struct Entry {
    var name: String
    var hasToken = false
    var usesKeyring = false
    var apiProtocol: String?

    mutating func record(key: String, value: String) {
      switch key {
      case "token": hasToken = !value.isEmpty
      case "use_keyring": usesKeyring = value.lowercased() == "true"
      case "api_protocol": apiProtocol = value.isEmpty ? nil : value
      default: break
      }
    }
  }

  /// `key: value` or `key:` → (key, value). `nil` for a list item or a line without a key.
  private static func field(_ line: String) -> (String, String)? {
    guard !line.hasPrefix("-") else { return nil }
    if line.hasSuffix(":") { return (String(line.dropLast()), "") }
    guard let separator = line.range(of: ": ") else { return nil }
    let key = String(line[..<separator.lowerBound])
    let value = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
    return (key, unquoted(value))
  }

  private static func unquoted(_ value: String) -> String {
    guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else {
      return value
    }
    return String(value.dropFirst().dropLast())
  }
}
