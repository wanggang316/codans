import CodansCore
import Foundation

/// Remote analogue of the local foreground-job poller: reads each remote
/// pane's foreground process group over SSH so `AgentBinder` classifies and
/// releases agents in Server-project panes exactly like local ones, and the
/// busy-spinner classifier sees real commands instead of the local `ssh`
/// tunnel.
///
/// The connect script records each pane's controlling tty under
/// `~/.cache/codans/pane-ttys/<paneUUID>` on the host (see
/// `RemoteSurfaceCommand`); one probe per host walks those files and reports,
/// per pane, every process on that tty (`ps -t`). The `+` stat flag (member
/// of the tty's foreground process group) is filtered locally so the
/// host-side script stays a dumb enumerator that GNU and BSD `ps` both
/// satisfy.
nonisolated enum RemoteForegroundProbe {
  static let timeout: Duration = .seconds(10)
  static let maxOutputBytes = 256 * 1024

  /// Host-side directory the connect script records ttys into. `$HOME` stays
  /// unexpanded — the fragment and the script both run on the host.
  static let ttyDirectory = "$HOME/.cache/codans/pane-ttys"

  /// Shell fragment (terminated with `; `) the remote worktree shell runs
  /// before exec'ing: record this pane's controlling tty so the probe can
  /// find its foreground job later. Best-effort — a host without `tty` or a
  /// read-only home leaves the pane invisible to the probe, never breaks the
  /// shell. No apostrophes: it crosses several single-quoting layers.
  static func recordTTYFragment(paneUUID: String) -> String {
    "{ mkdir -p \"\(ttyDirectory)\" && tty >\"\(ttyDirectory)/\(paneUUID)\"; } >/dev/null 2>&1; "
  }

  /// POSIX enumerator: for each recorded pane tty that still exists, print
  ///
  ///     <paneUUID> <pid> <pgid> <stat> <args…>
  ///
  /// one line per process on that tty. Records whose tty vanished (the
  /// pane's session ended) are pruned so the directory cannot grow
  /// unboundedly.
  static let script = """
    dir="$HOME/.cache/codans/pane-ttys"
    [ -d "$dir" ] || exit 0
    for f in "$dir"/*; do
    [ -f "$f" ] || continue
    pane=$(basename "$f")
    t=$(cat "$f" 2>/dev/null)
    case "$t" in /dev/*) ;; *) rm -f "$f"; continue;; esac
    [ -e "$t" ] || { rm -f "$f"; continue; }
    ps -t "${t#/dev/}" -o pid=,pgid=,stat=,args= 2>/dev/null | while IFS= read -r line; do
    printf "%s %s\\n" "$pane" "$line"
    done
    done
    exit 0
    """

  /// One probe round-trip for `host`. Returns per-pane foreground jobs, or
  /// nil when the probe itself failed (unreachable host, ssh error) — the
  /// caller must then freeze pane state rather than emit empty jobs that
  /// would release live agent bindings during a network blip. A succeeding
  /// probe with no row for a registered pane genuinely means "no foreground
  /// job there" (session gone, or its tty record not yet written).
  static func run(
    host: RemoteHost,
    runner: any CommandRunner = FoundationCommandRunner()
  ) async -> [UUID: ForegroundJob]? {
    let (executable, arguments) = SSHCommand.invocation(
      host: host,
      executable: "/bin/sh",
      arguments: ["-c", script, "sh"],
      workingDirectory: nil,
      extraOptions: SSHCommand.backgroundProbeOptions
    )
    let outcome = await runner.run(
      executable: executable,
      arguments: arguments,
      env: ProcessInfo.processInfo.environment,
      cwd: URL(fileURLWithPath: NSHomeDirectory()),
      timeout: timeout,
      maxOutputBytes: maxOutputBytes
    )
    guard case .exited(let code, let stdout, _, _) = outcome, code == 0 else { return nil }
    guard let output = String(bytes: stdout, encoding: .utf8) else { return [:] }
    return parse(output: output)
  }

  /// Parse enumerator output into per-pane foreground jobs: keep only rows
  /// whose stat carries `+` (the tty's foreground process group), group by
  /// pane, and adopt the process group those rows agree on.
  static func parse(output: String) -> [UUID: ForegroundJob] {
    struct Row {
      let pid: Int32
      let pgid: Int32
      let args: String
    }
    var rowsByPane: [UUID: [Row]] = [:]
    for line in output.split(separator: "\n") {
      let fields = line.split(separator: " ", omittingEmptySubsequences: true)
      guard fields.count >= 5,
        let pane = UUID(uuidString: String(fields[0])),
        let pid = Int32(fields[1]),
        let pgid = Int32(fields[2]),
        fields[3].contains("+")
      else { continue }
      let args = fields.dropFirst(4).joined(separator: " ")
      rowsByPane[pane, default: []].append(Row(pid: pid, pgid: pgid, args: args))
    }
    var jobs: [UUID: ForegroundJob] = [:]
    for (pane, rows) in rowsByPane {
      guard let pgid = rows.first?.pgid else { continue }
      let processes = rows.filter { $0.pgid == pgid }.map { row in
        ForegroundProcess(
          pid: row.pid,
          parentPID: 0,
          processGroupID: row.pgid,
          argv0: row.args.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? row.args,
          commandLine: row.args
        )
      }
      jobs[pane] = ForegroundJob(processGroupID: pgid, processes: processes)
    }
    return jobs
  }
}
