import ArgumentParser
import Darwin
import Foundation
import CodansIPC
import CodansKit

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
      let path = SocketDiscovery.resolve()
      if SocketDiscovery.isReachable(path: path) {
        try Renderer.emitObject(
          ["path": path, "alreadyRunning": true],
          mode: renderMode,
          textRender: { _ in "already running at \(path)" }
        )
        return
      }

      let launch = Self.launchArguments()
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

  private static func launchArguments() -> (arguments: [String], description: String) {
    if let appPath = coBuiltAppPath() {
      return (["-g", appPath], "open -g \(appPath)")
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

  func run() throws {
    let path = globals.resolvedSocketPath
    let reachable = SocketDiscovery.isReachable(path: path)
    try Renderer.emitObject(
      [
        "socketPath": path,
        "socketReachable": reachable,
        "socketFromEnvironment": ProcessInfo.processInfo.environment["CODANS_SOCKET_PATH"] != nil,
        "clientVersion": CodansCLI.version,
      ],
      mode: globals.renderMode
    ) { obj in
      """
      codans                \(obj["clientVersion"] ?? "?")
      socket            \(obj["socketPath"] ?? "?")
      socketReachable   \(obj["socketReachable"] ?? false)
      """
    }
  }
}
