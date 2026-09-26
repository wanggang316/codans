import Foundation

/// The curated "common command → icon" mapping. One table serves every
/// surface that needs a glyph for a command line: detected command
/// suggestions, and the live foreground-process list.
///
/// Resolution for a manifest entry, most specific first:
/// 1. the entry is named after a tool (`storybook`, `docker:up`) → its mark;
/// 2. the entry names an action (`build`, `test:unit`) → the action's SF
///    Symbol, so a manifest's entries stay distinguishable instead of all
///    wearing the runner's logo;
/// 3. the entry's body invokes a known tool (`prisma generate`) → its mark;
/// 4. the runner that executes the entry (`pnpm run …`, `make …`) → its mark.
public nonisolated enum CommandIconCatalog {
  public static func icon(forEntryName name: String, command: String, body: String?) -> CommandIconRef? {
    let segments = entrySegments(name)
    if let head = segments.first, let tool = toolIcon(forToken: head) {
      return tool
    }
    for segment in segments {
      if let action = actionSymbols[segment] { return .symbol(action) }
    }
    if let body, let tool = firstToolIcon(inCommandLine: body) {
      return tool
    }
    return firstToolIcon(inCommandLine: command)
  }

  /// Icon for a running executable (`node`, `/usr/local/bin/cargo`,
  /// `python3.12`), or nil when the executable is not a known tool.
  public static func toolIcon(forExecutable executable: String) -> CommandIconRef? {
    toolIcon(forToken: normalizedExecutable(executable))
  }

  /// The tool that executes a command line, looking past a leading
  /// `cd <dir> &&` so a nested entry resolves to its runner, not its folder.
  public static func runnerIcon(forCommand command: String) -> CommandIconRef? {
    var line = Substring(command)
    if line.hasPrefix("cd "), let separator = line.range(of: "&&") {
      line = line[separator.upperBound...]
    }
    return firstToolIcon(inCommandLine: String(line))
  }

  // MARK: - Tables

  /// Action words people name entries after → SF Symbol. Keys are lowercase
  /// single segments of an entry name.
  static let actionSymbols: [String: String] = {
    var table: [String: String] = [:]
    func map(_ words: [String], _ symbol: String) {
      for word in words { table[word] = symbol }
    }
    map(["dev", "start", "serve", "server", "run", "up"], "play.fill")
    map(["watch", "preview"], "eye.fill")
    map(["build", "compile", "bundle", "package", "dist"], "hammer.fill")
    map(["test", "tests", "spec", "unit", "e2e", "integration"], "testtube.2")
    map(["coverage", "cov"], "chart.bar.fill")
    map(["lint", "check", "vet", "clippy"], "checklist")
    map(["typecheck", "types", "tsc"], "checkmark.shield.fill")
    map(["format", "fmt"], "wand.and.stars")
    map(["clean", "clear", "reset"], "trash.fill")
    map(["install", "setup", "bootstrap", "deps", "prepare"], "shippingbox.fill")
    map(["update", "upgrade", "bump"], "arrow.up.circle.fill")
    map(["docs", "doc"], "book.fill")
    map(["deploy", "release", "publish", "ship"], "paperplane.fill")
    map(["migrate", "migration", "db", "seed"], "cylinder.split.1x2.fill")
    map(["generate", "gen", "codegen"], "gearshape.2.fill")
    map(["bench", "benchmark", "perf"], "speedometer")
    map(["debug"], "ladybug.fill")
    map(["ci"], "arrow.triangle.2.circlepath")
    map(["stop", "down", "kill"], "stop.fill")
    map(["logs", "log"], "doc.text.fill")
    return table
  }()

  /// Executable / entry-name token → icon. A token is a bare lowercase
  /// command name (paths and `@version` suffixes are stripped first).
  static let toolIcons: [String: CommandIconRef] = {
    var table: [String: CommandIconRef] = [:]
    func map(_ tokens: [String], _ mark: ToolMark) {
      for token in tokens { table[token] = .mark(mark) }
    }
    map(["node", "nodejs", "tsx", "ts-node"], .nodejs)
    map(["npm", "npx"], .npm)
    map(["pnpm", "pnpx"], .pnpm)
    map(["yarn"], .yarn)
    map(["bun", "bunx"], .bun)
    map(["deno"], .deno)
    map(["vite"], .vite)
    map(["vitest"], .vitest)
    map(["jest"], .jest)
    map(["eslint"], .eslint)
    map(["prettier"], .prettier)
    map(["biome"], .biome)
    map(["typescript"], .typescript)
    map(["webpack", "webpack-cli", "webpack-dev-server"], .webpack)
    map(["esbuild"], .esbuild)
    map(["storybook", "start-storybook", "build-storybook"], .storybook)
    map(["cypress"], .cypress)
    map(["turbo", "turborepo"], .turborepo)
    map(["nx"], .nx)
    map(["next"], .nextjs)
    map(["nuxt", "nuxi"], .nuxt)
    map(["astro"], .astro)
    map(["svelte-kit", "svelte"], .svelte)
    map(["ng", "angular"], .angular)
    map(["expo"], .expo)
    map(["electron", "electron-builder", "electron-forge"], .electron)
    map(["tauri"], .tauri)
    map(["flutter"], .flutter)
    map(["dart"], .dart)
    map(["python", "python3", "pip", "pip3"], .python)
    map(["uv", "uvx"], .uv)
    map(["poetry"], .poetry)
    map(["pytest"], .pytest)
    map(["django-admin", "manage.py", "django"], .django)
    map(["flask"], .flask)
    map(["ruby", "bundle", "bundler", "rake", "gem"], .ruby)
    map(["rails"], .rails)
    map(["php", "composer", "artisan"], .php)
    map(["swift", "xcodebuild"], .swift)
    map(["kotlin", "kotlinc"], .kotlin)
    map(["gradle", "gradlew"], .gradle)
    map(["go", "gofmt"], .go)
    map(["cargo", "rustc", "rustup"], .rust)
    map(["mix", "elixir", "iex"], .elixir)
    map(["make", "gmake"], .make)
    map(["cmake", "ctest"], .cmake)
    map(["just"], .just)
    map(["task"], .task)
    map(["mise"], .mise)
    map(["docker", "docker-compose", "compose"], .docker)
    map(["kubectl", "kubernetes", "k8s", "helm"], .kubernetes)
    map(["terraform", "tf"], .terraform)
    map(["ansible", "ansible-playbook"], .ansible)
    map(["prisma"], .prisma)
    map(["git"], .git)
    map(["gh"], .github)
    // Playwright's mark is a pair of theatre masks; SF has exactly that.
    table["playwright"] = .symbol("theatermasks.fill")
    return table
  }()

  // MARK: - Tokenising

  static func toolIcon(forToken token: String) -> CommandIconRef? {
    if let icon = toolIcons[token] { return icon }
    // `python3.12`, `pip3.11`
    if token.range(of: #"^(python|pip)[23](\.[0-9]+)?$"#, options: .regularExpression) != nil {
      return .mark(.python)
    }
    return nil
  }

  /// Lowercase name segments: `test:unit` → [test, unit], `docker-up` →
  /// [docker, up]. Whole-name first so hyphenated tool names (`svelte-kit`)
  /// still match as one token.
  static func entrySegments(_ name: String) -> [String] {
    let lowered = name.lowercased()
    let parts = lowered.split(whereSeparator: { ":-_./ ".contains($0) }).map(String.init)
    if parts.count > 1, toolIcons[lowered] != nil { return [lowered] + parts }
    return parts
  }

  /// First known tool among the command line's words, skipping env
  /// assignments (`NODE_ENV=production`) and wrappers.
  static func firstToolIcon(inCommandLine line: String) -> CommandIconRef? {
    let words = line.split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "&" || $0 == "|" })
    for word in words {
      let raw = String(word)
      if raw.contains("=") || raw.hasPrefix("-") { continue }
      let token = normalizedExecutable(raw)
      if wrappers.contains(token) { continue }
      if let icon = toolIcon(forToken: token) { return icon }
    }
    return nil
  }

  /// Words that launch another command rather than being the tool itself.
  static let wrappers: Set<String> = ["env", "sudo", "exec", "time", "nohup", "cross-env", "dotenv", "run", "x"]

  /// `./node_modules/.bin/vite` → `vite`, `create-vite@latest` →
  /// `create-vite`, `NPM` → `npm`.
  static func normalizedExecutable(_ raw: String) -> String {
    var token = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"'()"))
    if let slash = token.lastIndex(of: "/") { token = String(token[token.index(after: slash)...]) }
    if let at = token.dropFirst().firstIndex(of: "@") { token = String(token[..<at]) }
    return token
  }
}
