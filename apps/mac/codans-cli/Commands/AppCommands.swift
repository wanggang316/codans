import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Darwin
import Foundation

struct StatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show the running Codans app status."
  )

  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      struct Status: Codable {
        let server: String
        let uptimeSeconds: Double
        let connectedClients: Int
      }
      let s: Status = try await client.call(.systemStatus, params: EmptyParams())
      try Renderer.emitObject(
        [
          "server": s.server,
          "uptimeSeconds": s.uptimeSeconds,
          "connectedClients": s.connectedClients,
        ],
        mode: globals.renderMode
      ) { obj in
        let uptime = obj["uptimeSeconds"] as? Double ?? 0
        return """
          server             \(obj["server"] ?? "?")
          uptime             \(String(format: "%.1f", uptime))s
          connectedClients   \(obj["connectedClients"] ?? 0)
          """
      }
    }
  }
}

struct LaunchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "launch",
    abstract: "Start Codans and wait for its command socket."
  )

  @Flag(name: .long, help: "Emit JSON on stdout instead of human-readable text.")
  var json: Bool = false
  @Option(name: .long, help: "Seconds to wait for the socket after launching.")
  var wait: Double = 10

  private var renderMode: RenderMode {
    json ? .json : .text(useColor: true)
  }

  func run() async throws {
    await CommandRunner.run {
      let path = try SocketDiscovery.resolve()
      let probe = SocketDiscovery.probe(path: path)
      if probe.isReachable {
        try Renderer.emitObject(
          ["path": path, "alreadyRunning": true],
          mode: renderMode,
          textRender: { _ in "already running at \(path)" }
        )
        return
      }
      // A permission or wrong-path failure is not something starting the
      // app can clear — report it now instead of burning `--wait` seconds
      // polling a socket we could never connect to.
      if let failure = probe.failure, !failure.kind.isResolvedByLaunching {
        throw CLIError(
          code: CLIExitCode.from(failure),
          message: failure.message,
          hint: failure.hint
        )
      }

      let launch = try Self.launchArguments()
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      process.arguments = launch.arguments
      do {
        try process.run()
        process.waitUntilExit()
      } catch {
        throw CLIError(code: .launchTimeout, message: "failed to invoke /usr/bin/open: \(error)")
      }
      guard process.terminationStatus == 0 else {
        throw CLIError(
          code: .launchTimeout,
          message: "\(launch.description) exited with status \(process.terminationStatus)"
        )
      }

      let deadline = Date(timeIntervalSinceNow: wait)
      while Date() < deadline {
        if SocketDiscovery.isReachable(path: path) {
          try Renderer.emitObject(
            ["path": path, "alreadyRunning": false],
            mode: renderMode,
            textRender: { _ in "launched; socket up at \(path)" }
          )
          return
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw CLIError(
        code: .launchTimeout,
        message: "socket \(path) did not become reachable within \(wait)s"
      )
    }
  }

  /// Prefer the app this binary ships inside. Only the release CLI may fall
  /// back to LaunchServices by name: `open -ga Codans` resolves to the
  /// installed release app, which a development CLI must never start.
  private static func launchArguments() throws -> (arguments: [String], description: String) {
    if let appPath = coBuiltAppPath() {
      return (["-g", appPath], "open -g \(appPath)")
    }
    guard BuildChannel.current == .release else {
      throw CLIError(
        code: .notFound,
        message: "cannot find the development app this CLI was built with",
        hint: "run the copy embedded in the Debug Codans.app, or open that app yourself"
      )
    }
    return (["-ga", "Codans"], "open -ga Codans")
  }

  private static func coBuiltAppPath() -> String? {
    guard let executable = Bundle.main.executableURL else { return nil }
    let fileManager = FileManager.default
    let executableDirectory = executable.deletingLastPathComponent()
    let sibling = executableDirectory.appendingPathComponent("Codans.app")
    if fileManager.fileExists(atPath: sibling.path) {
      return sibling.path
    }

    let embeddedApp =
      executableDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    if embeddedApp.pathExtension == "app", fileManager.fileExists(atPath: embeddedApp.path) {
      return embeddedApp.path
    }
    return nil
  }
}

struct DoctorCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract: "Check local CLI configuration and app reachability."
  )

  @OptionGroup var globals: GlobalOptions

  /// `socketStatus` value for a pane that belongs to the other build channel.
  /// Not a `SocketFailureKind`: nothing was dialled. The hint carries the
  /// command to switch to.
  static let wrongChannelStatus = "wrong-channel"

  func run() throws {
    // `socketStatus` is the scriptable form of "why not": one of the
    // SocketFailureKind raw values, `wrong-channel`, or "ok".
    // `socketReachable` stays for callers that only need the boolean.
    var payload: [String: Any] = [
      "client": CodansCLI.commandName,
      "clientVersion": CodansCLI.version,
      "channel": BuildChannel.current.rawValue,
      "socketFromEnvironment":
        ProcessInfo.processInfo.environment[CodansEnvironment.Key.socketPath.rawValue] != nil,
    ]
    do {
      let path = try globals.resolveSocketPath()
      let probe = SocketDiscovery.probe(path: path)
      payload["socketPath"] = path
      payload["socketReachable"] = probe.isReachable
      payload["socketStatus"] = probe.failure?.kind.rawValue ?? "ok"
      if let hint = probe.failure?.hint {
        payload["socketHint"] = hint
      }
    } catch {
      // Diagnostic command: report the refusal instead of exiting on it, so
      // a script reads the status and switches command.
      payload["socketPath"] = error.socketPath
      payload["socketReachable"] = false
      payload["socketStatus"] = Self.wrongChannelStatus
      payload["socketHint"] = error.hint
    }
    try Renderer.emitObject(payload, mode: globals.renderMode) { obj in
      var lines = """
        client            \(obj["client"] ?? "?") \(obj["clientVersion"] ?? "?") (\(obj["channel"] ?? "?"))
        socket            \(obj["socketPath"] ?? "?")
        socketReachable   \(obj["socketReachable"] ?? false)
        socketStatus      \(obj["socketStatus"] ?? "?")
        """
      if let hint = obj["socketHint"] as? String {
        lines += "\n  hint: \(hint)"
      }
      return lines
    }
  }
}
