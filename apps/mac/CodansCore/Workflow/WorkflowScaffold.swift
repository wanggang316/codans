import Foundation

/// Creates a new `<id>.workflow.yaml` in a scope directory — from a blank
/// starter or as a copy of an existing definition. The file is the whole
/// workflow (the file name is its id), so creating one is just writing a
/// valid document where discovery looks; nothing is registered anywhere.
public nonisolated enum WorkflowScaffold {
  public enum Source: Equatable, Sendable {
    /// A small, valid starter: one launched helper whose delivery is handed
    /// back to the pane that started the run.
    case blank
    /// Another definition's text, renamed.
    case copy(yaml: String)
  }

  public enum Failure: Error, Equatable, Sendable {
    case invalidID(String)
    case alreadyExists(path: String)

    public var message: String {
      switch self {
      case .invalidID(let id):
        return
          "\"\(id)\" is not a valid workflow id — use lowercase letters, digits, \"-\", \"_\" or \".\", starting with a letter or digit."
      case .alreadyExists(let path):
        return "\(path) already exists."
      }
    }
  }

  /// The id a display name suggests: lowercase, runs of anything else
  /// collapsed to "-". `nil` when nothing usable is left.
  public static func suggestedID(forName name: String) -> String? {
    var id = ""
    var pendingDash = false
    for scalar in name.lowercased().unicodeScalars {
      let isWordScalar =
        (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39)
      if isWordScalar {
        if pendingDash, !id.isEmpty { id.append("-") }
        id.unicodeScalars.append(scalar)
        pendingDash = false
      } else {
        pendingDash = true
      }
    }
    let trimmed = String(id.prefix(64))
    return WorkflowDefinition.isValidIdentifier(trimmed) ? trimmed : nil
  }

  public static func fileURL(id: String, in directory: URL) -> URL {
    directory.appendingPathComponent(id + WorkflowDocumentParser.fileSuffix, isDirectory: false)
  }

  /// The document `create` writes, exposed so callers can preview or test it.
  public static func document(name: String, source: Source) -> String {
    switch source {
    case .blank:
      return blankDocument(name: name)
    case .copy(let yaml):
      return renamed(yaml, to: name)
    }
  }

  /// Writes the new file and returns its URL. Never overwrites: an existing
  /// file with that id is the user's.
  @discardableResult
  public static func create(id: String, name: String, source: Source, in directory: URL) throws -> URL {
    guard WorkflowDefinition.isValidIdentifier(id) else { throw Failure.invalidID(id) }
    let url = fileURL(id: id, in: directory)
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: url.path(percentEncoded: false)) else {
      throw Failure.alreadyExists(path: url.path(percentEncoded: false))
    }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = Data(document(name: name, source: source).utf8)
    // `.withoutOverwriting` closes the race between the check and the write.
    try data.write(to: url, options: [.withoutOverwriting])
    return url
  }

  // MARK: - Documents

  static func quoted(_ text: String) -> String {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  private static func blankDocument(name: String) -> String {
    """
    name: \(quoted(name))
    description: One line on what this workflow is for.

    inputs:
      task:
        description: What the helper should do.
        type: string
        required: true

    roles:
      me:
        source: current
      helper:
        source: launch
        placement: split
        direction: right
        background: true

    steps:
      - name: Ask the helper
        id: ask
        launch: helper
        prompt: |
          ${{ inputs.task }}

          Answer in markdown with a "## Result" section.
        expect:
          delivery: result
          sections: ["## Result"]

      - name: Hand the result back
        message: me
        text: "[codans] The helper finished — read ${{ deliveries.result.path }} and continue."

    """
  }

  /// Replaces the top-level `name:` line (column 0) or, when the source has
  /// none, puts one first. Everything else is kept byte for byte.
  private static func renamed(_ yaml: String, to name: String) -> String {
    var lines = yaml.components(separatedBy: "\n")
    let nameLine = "name: \(quoted(name))"
    if let index = lines.firstIndex(where: { $0.hasPrefix("name:") }) {
      lines[index] = nameLine
    } else {
      lines.insert(nameLine, at: 0)
    }
    return lines.joined(separator: "\n")
  }
}
