import Foundation

public nonisolated struct ForegroundProcess: Sendable, Equatable, Codable {
  public var pid: Int32
  public var parentPID: Int32
  public var processGroupID: Int32
  public var argv0: String
  public var startedAt: Date?
  public var commandLine: String
  /// The kernel's argv, when it was readable. `commandLine` is this joined
  /// with spaces, which loses the boundaries of arguments that contain
  /// spaces (`ssh -o "SetEnv A=b"`); nil for samples without it (a remote
  /// probe reports only the joined line).
  public var arguments: [String]?

  public init(
    pid: Int32,
    parentPID: Int32,
    processGroupID: Int32,
    argv0: String,
    commandLine: String,
    startedAt: Date? = nil,
    arguments: [String]? = nil
  ) {
    self.startedAt = startedAt
    self.arguments = arguments
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

  /// argv when known, else the whitespace-split command line.
  public var argumentsOrTokens: [String] {
    arguments ?? commandTokens
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
