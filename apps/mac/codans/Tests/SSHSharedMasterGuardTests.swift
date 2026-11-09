import CodansCore
import Foundation
import Testing

@testable import Codans

/// Runs `SSHCommand.sharedMasterGuard` under `/bin/sh` against a fake `ssh`
/// that stands in for the master: `-O check` succeeds only when the `alive`
/// marker exists, `-G` prints the ControlPath, and any other call "creates"
/// the master after a short auth delay (so concurrent guards overlap).
struct SSHSharedMasterGuardTests {
  private let host = RemoteHost(alias: "example.com", username: "alice", port: 2222)

  @Test
  func liveMasterSkipsCreationAndKeepsTheSocket() throws {
    let state = try Self.makeState()
    try Data().write(to: state.appending(path: "alive"))
    try Data().write(to: state.appending(path: "cm"))

    try Self.runGuards(count: 1, host: host, state: state)

    #expect(try Self.lines(state, "creates").isEmpty)
    #expect(try Self.lines(state, "calls").allSatisfy { $0.contains("-O check") })
    #expect(FileManager.default.fileExists(atPath: state.appending(path: "cm").path))
  }

  @Test
  func deadMasterIsCreatedOnceUnderTheControlPathLock() throws {
    let state = try Self.makeState()
    // A socket file left by a killed master. The guard never removes it; ssh
    // does that itself when its connect is refused.
    try Data().write(to: state.appending(path: "cm"))

    try Self.runGuards(count: 1, host: host, state: state)

    let creates = try Self.lines(state, "creates")
    #expect(creates.count == 1)
    #expect(creates.first?.contains("ControlMaster=auto") == true)
    #expect(creates.first?.contains("BatchMode=yes") == true)
    #expect(creates.first?.hasSuffix("-n -p 2222 alice@example.com true") == true)
    #expect(FileManager.default.fileExists(atPath: state.appending(path: "cm.lock").path))
    #expect(FileManager.default.fileExists(atPath: state.appending(path: "cm").path))
  }

  @Test
  func concurrentLinesShareOneNewMaster() throws {
    let state = try Self.makeState()

    try Self.runGuards(count: 6, host: host, state: state)

    // Without the lock each line would create its own master; with it, the
    // lines that waited find the new master and create nothing.
    #expect(try Self.lines(state, "creates").count == 1)
  }

  @Test
  func invocationRunsTheGuardBeforeExecingSSH() {
    let (executable, arguments) = SSHCommand.invocation(
      host: host,
      executable: "git",
      arguments: ["status"],
      workingDirectory: "/srv/app",
      extraOptions: SSHCommand.backgroundProbeOptions
    )
    #expect(executable.path == "/bin/sh")
    #expect(arguments[0] == "-c")
    #expect(arguments[1].hasPrefix("if ! '/usr/bin/ssh' "))
    #expect(arguments[1].hasSuffix("exec \"$@\""))
    #expect(Array(arguments[2...3]) == [SSHCommand.guardShellName, "/usr/bin/ssh"])
  }

  @Test
  func terminalLineKeepsCreatorOutputVisible() {
    let line = SSHCommand.commandLine(host: host, remoteCommand: "exec \"$SHELL\" -l")
    let guardScript = SSHCommand.sharedMasterGuard(
      host: host, extraOptions: SSHCommand.interactiveOptions, quiet: false
    )
    #expect(line.hasPrefix(guardScript + "/usr/bin/ssh "))
    #expect(!guardScript.contains("/dev/null 2>&1; fi"))
    #expect(guardScript.contains("'ConnectTimeout=30' -n"))
  }

  // MARK: - Helpers

  private static func makeState() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "codans-ssh-guard-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fake = """
      #!/bin/sh
      state=\(SSHCommand.shellQuote(dir.path))
      echo "$*" >> "$state/calls"
      case " $* " in
      *" -O check "*) [ -f "$state/alive" ] && exit 0; exit 255 ;;
      *" -G "*) echo "controlpath $state/cm"; exit 0 ;;
      esac
      [ -f "$state/alive" ] && exit 0
      sleep 0.3
      echo "$*" >> "$state/creates"
      : > "$state/alive"
      """
    let ssh = dir.appending(path: "ssh")
    try fake.write(to: ssh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
    return dir
  }

  private static func runGuards(count: Int, host: RemoteHost, state: URL) throws {
    let script = SSHCommand.sharedMasterGuard(
      host: host,
      extraOptions: SSHCommand.backgroundProbeOptions,
      quiet: true,
      sshPath: state.appending(path: "ssh").path
    )
    let processes = try (0..<count).map { _ in
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: "/bin/sh")
      proc.arguments = ["-c", script + "exit 0"]
      try proc.run()
      return proc
    }
    for proc in processes {
      proc.waitUntilExit()
      #expect(proc.terminationStatus == 0)
    }
  }

  private static func lines(_ state: URL, _ name: String) throws -> [String] {
    let url = state.appending(path: name)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }
}
