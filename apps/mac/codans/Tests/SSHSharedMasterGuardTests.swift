import CodansCore
import Foundation
import Testing

@testable import Codans

/// Runs `SSHCommand.sharedMasterLine` under `/bin/sh` against a fake `ssh`
/// that stands in for the masters. A master at ControlPath `P` is live when
/// `P.alive` exists and refuses sessions (sshd `MaxSessions`) when `P.full`
/// exists. `-O check` reports liveness, `-G` prints the ControlPath, a `true`
/// line creates the master after a short auth delay (so concurrent lines
/// overlap), and a line that cannot use the master runs its `ProxyCommand`,
/// like ssh does. Each line that ran records how it ran in `runs`.
struct SSHSharedMasterGuardTests {
  private let host = RemoteHost(alias: "example.com", username: "alice", port: 2222)

  @Test
  func liveMasterRunsTheLineAndKeepsTheSocket() throws {
    let state = try Self.makeState()
    try Self.mark(state, "cm.alive")

    let result = try Self.runLines(count: 1, host: host, state: state)

    #expect(result.statuses == [0])
    #expect(try Self.lines(state, "creates").isEmpty)
    #expect(try Self.lines(state, "runs") == ["mux \(state.path)/cm"])
    #expect(FileManager.default.fileExists(atPath: state.appending(path: "cm.alive").path))
  }

  @Test
  func deadMasterIsCreatedOnceUnderTheControlPathLock() throws {
    let state = try Self.makeState()

    try Self.runLines(count: 1, host: host, state: state)

    let creates = try Self.lines(state, "creates")
    #expect(creates.count == 1)
    #expect(creates.first?.contains("ControlMaster=auto") == true)
    #expect(creates.first?.contains("ControlPath=\(state.path)/cm ") == true)
    #expect(creates.first?.contains("BatchMode=yes") == true)
    #expect(creates.first?.hasSuffix("-n -p 2222 alice@example.com true") == true)
    #expect(FileManager.default.fileExists(atPath: state.appending(path: "cm.lock").path))
    #expect(try Self.lines(state, "runs") == ["mux \(state.path)/cm"])
  }

  @Test
  func concurrentLinesShareOneNewMaster() throws {
    let state = try Self.makeState()

    try Self.runLines(count: 6, host: host, state: state)

    // Without the lock each line would create its own master; with it, the
    // lines that waited find the new master and create nothing.
    #expect(try Self.lines(state, "creates").count == 1)
    #expect(try Self.lines(state, "runs").count == 6)
  }

  @Test
  func lineStatusIsTheStatusOfSSH() throws {
    let state = try Self.makeState()
    try Self.mark(state, "cm.alive")
    try "7".write(to: state.appending(path: "rc"), atomically: true, encoding: .utf8)

    let result = try Self.runLines(count: 1, host: host, state: state)

    // A line that ran is never run again, whatever its status.
    #expect(result.statuses == [7])
    #expect(try Self.lines(state, "runs").count == 1)
  }

  @Test
  func fullMasterMovesTheLineToTheNextMaster() throws {
    let state = try Self.makeState()
    try Self.mark(state, "cm.alive")
    try Self.mark(state, "cm.full")

    try Self.runLines(count: 1, host: host, state: state)

    // The full master stays as it is; the line creates the next one (one
    // authentication) and runs over it, with no private connection.
    let creates = try Self.lines(state, "creates")
    #expect(creates.count == 1)
    #expect(creates.first?.contains("ControlPath=\(state.path)/cm-1 ") == true)
    #expect(try Self.lines(state, "runs") == ["mux \(state.path)/cm-1"])
    #expect(FileManager.default.fileExists(atPath: state.appending(path: "cm.alive").path))
  }

  @Test
  func masterThatCannotBeCreatedLeavesTheLineToSSH() throws {
    let state = try Self.makeState()
    try Self.mark(state, "nocreate")

    try Self.runLines(count: 1, host: host, state: state)

    // No live master to use: the line runs with `ControlMaster=auto`, as
    // before, so ssh shows its own auth prompt or error. No other master is
    // tried, so an unreachable host costs one attempt, not one per master.
    #expect(try Self.lines(state, "runs") == ["auto \(state.path)/cm"])
    #expect(try Self.lines(state, "calls").allSatisfy { !$0.contains("/cm-1") })
  }

  @Test
  func allMastersFullUsesItsOwnConnectionWithANotice() throws {
    let state = try Self.makeState()
    for path in SSHCommand.masterControlPaths(controlPath: "cm") {
      try Self.mark(state, "\(path).alive")
      try Self.mark(state, "\(path).full")
    }

    let quiet = try Self.runLines(count: 1, host: host, state: state)
    let terminal = try Self.runLines(count: 1, host: host, state: state, quiet: false)

    #expect(try Self.lines(state, "runs") == ["own", "own"])
    // The own connection is its own transport: it needs the keepalives a
    // master would carry, or a dead network never ends the terminal line.
    let ownCalls = try Self.lines(state, "calls").filter { $0.contains("ControlPath=none") }
    #expect(ownCalls.count == 2)
    #expect(
      ownCalls.allSatisfy {
        $0.contains("-o ServerAliveInterval=5 -o ServerAliveCountMax=3")
      })
    #expect(try Self.lines(state, "creates").isEmpty)
    #expect(quiet.stderr.isEmpty)
    #expect(terminal.stderr.contains("All shared SSH connections to this host are full"))
  }

  @Test
  func runnerTimeoutAlsoStopsTheCreator() async throws {
    let state = try Self.makeState()
    try Self.mark(state, "hang")
    let script = Self.line(host: host, state: state, quiet: true)

    // The lock wait can outlast a probe's timeout. `Process` makes the shell
    // a process-group leader and `terminate()` signals that whole group, so
    // `lockf` and the creating `ssh` stop with the probe.
    let outcome = await FoundationCommandRunner().run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", script],
      env: [:],
      cwd: state,
      timeout: .seconds(1),
      maxOutputBytes: 1024
    )

    guard case .timedOut = outcome else {
      Issue.record("expected a timeout, got \(outcome)")
      return
    }
    let pidText = try String(contentsOf: state.appending(path: "creator.pid"), encoding: .utf8)
    let creator = try #require(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(await Self.eventually { kill(creator, 0) != 0 })
  }

  @Test
  func invocationPassesTheSSHArgvToTheSharedMasterLine() {
    let (executable, arguments) = SSHCommand.invocation(
      host: host,
      executable: "git",
      arguments: ["status"],
      workingDirectory: "/srv/app",
      extraOptions: SSHCommand.backgroundProbeOptions
    )
    #expect(executable.path == "/bin/sh")
    #expect(arguments[0] == "-c")
    #expect(
      arguments[1]
        == SSHCommand.sharedMasterLine(
          host: host, extraOptions: SSHCommand.backgroundProbeOptions, quiet: true,
          sshArguments: "\"$@\""
        )
    )
    #expect(arguments[2] == SSHCommand.guardShellName)
    #expect(Array(arguments[3...6]) == SSHCommand.backgroundProbeOptions)
  }

  @Test
  func terminalLineKeepsCreatorOutputVisible() {
    let line = SSHCommand.commandLine(host: host, remoteCommand: "exec \"$SHELL\" -l")
    let guardScript = SSHCommand.sharedMasterGuard(
      host: host, extraOptions: SSHCommand.interactiveOptions, quiet: false
    )
    #expect(line.hasPrefix("( "))
    #expect(line.contains(guardScript))
    #expect(!guardScript.contains("/dev/null 2>&1; fi"))
    #expect(guardScript.contains("'ConnectTimeout=30' -n"))
    #expect(line.contains("All shared SSH connections"))
  }

  // MARK: - Helpers

  private static func makeState() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "codans-ssh-guard-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fake = """
      #!/bin/sh
      state=\(SSHCommand.shellQuote(dir.path))
      all="$*"
      echo "$all" >> "$state/calls"
      cp=; cm=; proxy=; check=; config=; last=
      while [ $# -gt 0 ]; do
        case "$1" in
        -o) shift
          case "$1" in
          ControlPath=*) cp=${1#ControlPath=} ;;
          ControlMaster=*) cm=${1#ControlMaster=} ;;
          ProxyCommand=*) proxy=${1#ProxyCommand=} ;;
          esac ;;
        -O) shift; check=1 ;;
        -G) config=1 ;;
        esac
        last=$1
        shift
      done
      if [ -n "$check" ]; then [ -f "$cp.alive" ] && exit 0; exit 255; fi
      if [ -n "$config" ]; then echo "controlpath $cp"; exit 0; fi
      if [ "$last" = true ] && [ -f "$cp.alive" ]; then exit 0; fi
      if [ -f "$cp.alive" ] && [ ! -f "$cp.full" ]; then
        echo "mux $cp" >> "$state/runs"
        exit "$(cat "$state/rc" 2>/dev/null || echo 0)"
      fi
      if [ -n "$proxy" ]; then /bin/sh -c "exec $proxy"; exit 255; fi
      if [ "$cm" = no ]; then echo "own" >> "$state/runs"; exit 0; fi
      if [ "$last" = true ]; then
        [ -f "$state/nocreate" ] && exit 255
        if [ -f "$state/hang" ]; then echo $$ > "$state/creator.pid"; exec sleep 30; fi
        sleep 0.3
        echo "$all" >> "$state/creates"
        : > "$cp.alive"
        exit 0
      fi
      echo "auto $cp" >> "$state/runs"
      """
    let ssh = dir.appending(path: "ssh")
    try fake.write(to: ssh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
    return dir
  }

  private static func mark(_ state: URL, _ name: String) throws {
    try Data().write(to: state.appending(path: name))
  }

  private static func line(host: RemoteHost, state: URL, quiet: Bool) -> String {
    SSHCommand.sharedMasterLine(
      host: host,
      extraOptions: SSHCommand.backgroundProbeOptions,
      quiet: quiet,
      sshArguments: "-n 'remote command'",
      controlPath: state.appending(path: "cm").path,
      sshPath: state.appending(path: "ssh").path
    )
  }

  @discardableResult
  private static func runLines(
    count: Int, host: RemoteHost, state: URL, quiet: Bool = true
  ) throws -> (statuses: [Int32], stderr: String) {
    let script = line(host: host, state: state, quiet: quiet)
    let runs = try (0..<count).map { _ in
      let proc = Process()
      let stderr = Pipe()
      proc.executableURL = URL(fileURLWithPath: "/bin/sh")
      proc.arguments = ["-c", script]
      proc.standardError = stderr
      try proc.run()
      return (proc, stderr)
    }
    var errors = ""
    let statuses = runs.map { proc, stderr in
      errors +=
        String(bytes: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      proc.waitUntilExit()
      return proc.terminationStatus
    }
    return (statuses, errors)
  }

  private static func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
  }

  private static func lines(_ state: URL, _ name: String) throws -> [String] {
    let url = state.appending(path: name)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }
}
