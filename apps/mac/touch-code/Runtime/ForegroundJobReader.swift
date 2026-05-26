import Foundation
import TouchCodeCore

nonisolated struct ForegroundJobReader: Sendable {
  private let commandRunner: any CommandRunner
  private let psURL: URL
  private let environment: [String: String]

  init(
    commandRunner: any CommandRunner = FoundationCommandRunner(),
    psURL: URL = URL(fileURLWithPath: "/bin/ps"),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.commandRunner = commandRunner
    self.psURL = psURL
    self.environment = environment
  }

  func readJobs(processGroupIDs: Set<Int32>) async -> [Int32: ForegroundJob] {
    guard !processGroupIDs.isEmpty else { return [:] }
    let outcome = await commandRunner.run(
      executable: psURL,
      arguments: ["-axo", "pid=,ppid=,pgid=,command="],
      env: environment,
      cwd: URL(fileURLWithPath: "/"),
      timeout: .seconds(1),
      maxOutputBytes: 512 * 1024
    )

    guard case .exited(let code, let stdout, _, _) = outcome, code == 0 else { return [:] }

    let output = String(decoding: stdout, as: UTF8.self)
    var processesByGroup: [Int32: [ForegroundProcess]] = [:]
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let process = Self.parseProcessLine(String(line)),
        processGroupIDs.contains(process.processGroupID)
      else { continue }
      processesByGroup[process.processGroupID, default: []].append(process)
    }

    return processesByGroup.mapValues { processes in
      ForegroundJob(processGroupID: processes[0].processGroupID, processes: processes)
    }
  }

  static func parseProcessLine(_ line: String) -> ForegroundProcess? {
    let scanner = Scanner(string: line)
    scanner.charactersToBeSkipped = .whitespaces

    var pid = 0
    var parentPID = 0
    var processGroupID = 0
    guard scanner.scanInt(&pid),
      scanner.scanInt(&parentPID),
      scanner.scanInt(&processGroupID)
    else { return nil }

    let commandLine = String(line[scanner.currentIndex...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !commandLine.isEmpty else { return nil }
    let argv0 = commandLine.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? commandLine

    return ForegroundProcess(
      pid: Int32(pid),
      parentPID: Int32(parentPID),
      processGroupID: Int32(processGroupID),
      argv0: argv0,
      commandLine: commandLine
    )
  }
}
