import Foundation

/// Resolves the app-bundled `codans` binary's absolute URL. Mirrors
/// `SkillBundleLocator`'s 3-phase discovery so the installer can find the
/// binary in `.app` builds and in dev runs without hard-coding paths.
public enum CLIBundleLocator {
  public enum LocatorError: Error, Equatable {
    case binaryNotFound
  }

  /// Environment-variable override. Takes precedence over bundle lookup — used
  /// in dev to point the installer at a freshly-built `codans` outside the `.app`.
  public enum EnvKey {
    public static let binary = CodansEnvironment.Key.cliBinary.rawValue
  }

  /// Resolution order:
  /// 0. `$CODANS_CLI_BINARY` — dev override.
  /// 1. `<app>/Contents/Resources/bin/codans` — the canonical bundled helper
  ///    path used by release packaging and the system CLI installer.
  /// 2. `<Bundle.main.executableURL>.deletingLastPathComponent()/codans` —
  ///    sibling of the running app's main executable inside `Contents/MacOS/`.
  ///    This is Tuist's default placement when an `.app` depends on a
  ///    `commandLineTool` target.
  /// 3. Repo walk upward from `<executableURL>` looking for a `codans` under
  ///    typical Xcode / SPM Products directories (`.build/**/codans`).
  public static func locateBinary(
    executableURL: URL? = Bundle.main.executableURL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> URL {
    if let override = environment[EnvKey.binary], !override.isEmpty {
      let expanded = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
      if isExecutableFile(expanded) { return expanded }
    }
    if let executable = executableURL, let bundled = resourceBinary(from: executable) {
      return bundled
    }
    if let executable = executableURL {
      let sibling =
        executable
        .deletingLastPathComponent()
        .appendingPathComponent("codans", isDirectory: false)
      if isExecutableFile(sibling) { return sibling }
    }
    if let executable = executableURL, let walked = repoWalk(from: executable) {
      return walked
    }
    throw LocatorError.binaryNotFound
  }

  private static func resourceBinary(from executable: URL) -> URL? {
    let contentsDirectory = executable.deletingLastPathComponent().deletingLastPathComponent()
    guard contentsDirectory.lastPathComponent == "Contents" else { return nil }
    let candidate =
      contentsDirectory
      .appendingPathComponent("Resources", isDirectory: true)
      .appendingPathComponent("bin", isDirectory: true)
      .appendingPathComponent("codans", isDirectory: false)
    return isExecutableFile(candidate) ? candidate : nil
  }

  private static func isExecutableFile(_ url: URL) -> Bool {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
      return false
    }
    return fm.isExecutableFile(atPath: url.path)
  }

  /// Walk upward from `url`'s directory up to 12 levels, searching for a `codans`
  /// executable at each ancestor or inside `.build/<platform>/codans`. Returns the
  /// first match or nil. Mirrors `SkillBundleLocator.repoWalk` in spirit.
  private static func repoWalk(from url: URL) -> URL? {
    let fm = FileManager.default
    var directory = url.deletingLastPathComponent()
    for _ in 0..<12 {
      let siblingCandidates = [
        directory.appendingPathComponent("codans"),
        directory.appendingPathComponent(".build/Debug/codans"),
        directory.appendingPathComponent(".build/Release/codans"),
      ]
      for candidate in siblingCandidates {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue,
          fm.isExecutableFile(atPath: candidate.path)
        {
          return candidate
        }
      }
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path { break }
      directory = parent
    }
    return nil
  }
}
