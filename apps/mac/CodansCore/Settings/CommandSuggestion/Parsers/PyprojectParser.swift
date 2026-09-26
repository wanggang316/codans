import Foundation

/// `pyproject.toml` command tables, run through the project's own tool.
///
/// - `[project.scripts]` entry points, run via the detected tool (`uv run`,
///   `poetry run`, `pdm run`, `hatch run`), or bare when there is none — the
///   entry point is then expected on PATH from the active environment.
/// - `[tool.poetry.scripts]`, `[tool.pdm.scripts]` and
///   `[tool.hatch.envs.default.scripts]` through their own tool.
/// - The tool's everyday verbs: `uv sync` / `poetry install` / `pdm install`,
///   and `pytest` when the manifest mentions it.
///
/// The tool is the one whose lockfile exists, else whose `[tool.*]` table
/// the manifest configures.
public nonisolated struct PyprojectParser: CommandSuggestionParser {
  public let source = CommandSuggestionSource(id: "pyproject", displayName: "pyproject.toml")

  static let manifestPath = "pyproject.toml"
  /// Tool → (lockfile, `[tool.*]` table prefix, run prefix, install verb).
  static let tools: [(name: String, lockfile: String?, table: String, run: String, install: String?)] = [
    ("uv", "uv.lock", "tool.uv", "uv run", "uv sync"),
    ("poetry", "poetry.lock", "tool.poetry", "poetry run", "poetry install"),
    ("pdm", "pdm.lock", "tool.pdm", "pdm run", "pdm install"),
    ("hatch", nil, "tool.hatch", "hatch run", nil),
  ]

  public init() {}

  public var request: ManifestRequest {
    ManifestRequest(contentPaths: [Self.manifestPath], presencePaths: Self.tools.compactMap(\.lockfile))
  }

  public func suggestions(in snapshot: ManifestSnapshot) -> [CommandSuggestion] {
    guard let text = snapshot[Self.manifestPath] else { return [] }
    let tables = TOMLLite.tables(in: text)
    let tool =
      Self.tools.first { $0.lockfile.map(snapshot.exists) ?? false }
      ?? Self.tools.first { tool in tables.contains { $0 == tool.table || $0.hasPrefix(tool.table + ".") } }

    var suggestions: [CommandSuggestion] = []
    func add(_ name: String, _ command: String, _ detail: String?) {
      suggestions.append(CommandSuggestion(source: source, name: name, command: command, detail: detail))
    }
    func runner(_ prefix: String?, _ name: String) -> String {
      let token = CommandSuggestionToken.render(name)
      return prefix.map { "\($0) \(token)" } ?? token
    }

    for (name, value) in TOMLLite.entries(in: text, table: "project.scripts") {
      add(name, runner(tool?.run, name), TOMLLite.string(value))
    }
    for (name, value) in TOMLLite.entries(in: text, table: "tool.poetry.scripts") {
      add(name, runner("poetry run", name), TOMLLite.string(value))
    }
    for (name, value) in TOMLLite.entries(in: text, table: "tool.pdm.scripts") {
      let detail =
        TOMLLite.string(value) ?? TOMLLite.inlineField("cmd", in: value) ?? TOMLLite.inlineField("shell", in: value)
      add(name, runner("pdm run", name), detail)
    }
    for (name, value) in TOMLLite.entries(in: text, table: "tool.hatch.envs.default.scripts") {
      add(name, runner("hatch run", name), TOMLLite.string(value))
    }

    if let install = tool?.install {
      let verb = String(install.split(separator: " ").last ?? "install")
      add(verb, install, nil)
    }
    if text.contains("pytest") {
      add("pytest", tool.map { "\($0.run) pytest" } ?? "pytest", nil)
    }
    return suggestions
  }
}
