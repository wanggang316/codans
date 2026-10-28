import Darwin
import Foundation

/// Which data instance this process belongs to. A channel has one shared
/// instance (`~/.codans`, `~/.codans-dev`); a development build made in a
/// linked git worktree gets its own, named after the worktree, so the dev
/// apps of two branches never share a catalog, settings, daemons, or socket.
/// A branch that changes the catalog format therefore cannot break the data
/// another branch's build reads.
///
/// The build stamps the name into the app's Info.plist (`stamp-instance.sh`);
/// the main checkout stamps nothing and keeps the shared instance. The app
/// and the CLI embedded in it read the same Info.plist, so both resolve the
/// same paths. Release builds never read it.
///
/// A Debug test run is an instance of its own (`xctest`): the app target's
/// tests run inside the full app, which loads and saves the catalog, and must
/// never do that to a developer's data.
public nonisolated enum AppInstance {
  /// Info.plist key that carries the instance name.
  public static let infoPlistKey = "CodansInstance"
  /// Instance of every Debug test run.
  public static let testInstanceName = "xctest"

  /// This build's instance name, or `nil` for the channel's shared instance.
  public static let name: String? = {
    guard BuildChannel.current == .development else { return nil }
    if isTestRun(ProcessInfo.processInfo.environment) { return testInstanceName }
    guard let app = containingApp(executable: Bundle.main.executableURL) else { return nil }
    return name(inAppAt: app)
  }()

  /// XCTest sets these in the test runner and in the app that hosts tests.
  static func isTestRun(_ environment: [String: String]) -> Bool {
    environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
  }

  /// Names every instance-scoped resource: `~/.<slug>`,
  /// `~/Library/Caches/<slug>`, `/tmp/<slug>-<uid>.sock`.
  public static let slug: String = slug(channel: .current, name: name)

  public static func slug(channel: BuildChannel, name: String?) -> String {
    guard let name else { return channel.slug }
    return "\(channel.slug)-\(name)"
  }

  /// IPC socket of this build's instance.
  public static func socketPath(uid: uid_t = getuid()) -> String {
    "/tmp/\(slug)-\(uid).sock"
  }

  /// Lowercase letters, digits, and inner hyphens, at most 24 characters.
  /// Short because the runtime root holds one AF_UNIX socket per Tab, and
  /// `sun_path` is capped at 104 bytes.
  public static func isValid(_ name: String) -> Bool {
    guard (1...24).contains(name.count), name.first != "-", name.last != "-" else { return false }
    return name.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
  }

  /// The instance name stamped into the app at `appURL`. A missing or
  /// malformed value means the shared instance.
  static func name(inAppAt appURL: URL) -> String? {
    let plist = appURL.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let name = info[infoPlistKey] as? String, isValid(name)
    else { return nil }
    return name
  }

  /// The `.app` that contains `executable`: the app's own binary or the
  /// CLI embedded under `Contents/Resources/bin`, reached directly or
  /// through an installed symlink.
  static func containingApp(executable: URL?) -> URL? {
    guard var url = executable?.resolvingSymlinksInPath() else { return nil }
    while url.pathComponents.count > 1 {
      url.deleteLastPathComponent()
      if url.pathExtension == "app" { return url }
    }
    return nil
  }
}
