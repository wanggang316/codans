import Foundation

public nonisolated struct ForegroundProcess: Sendable, Equatable, Codable {
  public var pid: Int32
  public var parentPID: Int32
  public var processGroupID: Int32
  public var argv0: String
  public var commandLine: String

  public init(
    pid: Int32,
    parentPID: Int32,
    processGroupID: Int32,
    argv0: String,
    commandLine: String
  ) {
    self.pid = pid
    self.parentPID = parentPID
    self.processGroupID = processGroupID
    self.argv0 = argv0
    self.commandLine = commandLine
  }

  public var processName: String {
    (argv0 as NSString).lastPathComponent
  }

  public var commandTokens: [String] {
    commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
  }
}

public nonisolated struct ForegroundJob: Sendable, Equatable, Codable {
  public var processGroupID: Int32
  public var processes: [ForegroundProcess]

  public init(processGroupID: Int32, processes: [ForegroundProcess]) {
    self.processGroupID = processGroupID
    self.processes = processes.sorted { lhs, rhs in
      if lhs.pid == rhs.pid { return lhs.argv0 < rhs.argv0 }
      return lhs.pid < rhs.pid
    }
  }

  public var isEmpty: Bool {
    processes.isEmpty
  }
}
