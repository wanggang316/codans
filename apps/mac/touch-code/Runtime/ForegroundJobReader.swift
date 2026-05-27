import Darwin
import Foundation
import TouchCodeCore

nonisolated struct ForegroundJobReader: Sendable {
  private static let procargsRetryLimit = 3

  func resolveProcessGroupID(preferred: Int32?, childPID: Int32?) -> Int32? {
    if let preferred, preferred > 0 { return preferred }
    guard let childPID, childPID > 0 else { return nil }
    return Self.foregroundProcessGroupID(childPID: childPID)
  }

  func readJobs(processGroupIDs: Set<Int32>) -> [Int32: ForegroundJob] {
    var jobs: [Int32: ForegroundJob] = [:]
    for processGroupID in processGroupIDs where processGroupID > 0 {
      guard let job = Self.foregroundJob(processGroupID: processGroupID) else { continue }
      jobs[processGroupID] = job
    }
    return jobs
  }

  static func foregroundJob(processGroupID: Int32) -> ForegroundJob? {
    guard processGroupID > 0 else { return nil }
    let processes = processGroupPIDs(processGroupID).compactMap(process(pid:))
    guard !processes.isEmpty else { return nil }
    return ForegroundJob(processGroupID: processGroupID, processes: processes)
  }

  static func foregroundProcessGroupID(childPID: Int32) -> Int32? {
    guard childPID > 0,
      let info = processBSDInfo(pid: childPID)
    else { return nil }

    let processGroupID = Int32(info.e_tpgid)
    guard processGroupID > 0 else { return nil }
    return processGroupID
  }

  static func processGroupPIDs(_ processGroupID: Int32) -> [Int32] {
    guard processGroupID > 0 else { return [] }

    var capacity = 16
    while capacity <= 4096 {
      var pids = [Int32](repeating: 0, count: capacity)
      let byteCount = pids.withUnsafeMutableBufferPointer { buffer in
        proc_listpids(
          UInt32(PROC_PGRP_ONLY),
          UInt32(processGroupID),
          buffer.baseAddress,
          Int32(buffer.count * MemoryLayout<Int32>.size)
        )
      }
      guard byteCount > 0 else { return [] }

      let count = Int(byteCount) / MemoryLayout<Int32>.size
      let result = pids.prefix(count).filter { $0 > 0 }
      if count < capacity { return Array(result) }
      capacity *= 2
    }

    return []
  }

  static func process(pid: Int32) -> ForegroundProcess? {
    guard pid > 0,
      let info = processBSDInfo(pid: pid),
      let name = commandName(from: info)
    else { return nil }

    let arguments = processArguments(pid: pid)
    let argv0 = arguments?.first ?? name
    let commandLine = arguments?.joined(separator: " ") ?? name
    return ForegroundProcess(
      pid: pid,
      parentPID: Int32(info.pbi_ppid),
      processGroupID: Int32(info.pbi_pgid),
      argv0: argv0,
      commandLine: commandLine
    )
  }

  static func processBSDInfo(pid: Int32) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
    }
    return result == Int32(size) ? info : nil
  }

  static func commandName(from info: proc_bsdinfo) -> String? {
    let bytes = withUnsafeBytes(of: info.pbi_comm) { rawBuffer -> [UInt8] in
      Array(rawBuffer)
    }
    let end = bytes.firstIndex(of: 0) ?? bytes.count
    guard end > 0 else { return nil }
    return String(bytes: bytes[..<end], encoding: .utf8)
  }

  static func processArguments(pid: Int32) -> [String]? {
    guard let buffer = kernProcargs2(pid: pid) else { return nil }
    return procargs2Argv(buffer)
  }

  static func kernProcargs2(pid: Int32) -> [UInt8]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctlProcargs2(&mib, buffer: nil, size: &size) == 0, size > 0 else {
      return nil
    }

    for _ in 0..<procargsRetryLimit {
      var buffer = [UInt8](repeating: 0, count: size)
      var readSize = size
      let result = buffer.withUnsafeMutableBufferPointer { pointer in
        sysctlProcargs2(&mib, buffer: pointer.baseAddress, size: &readSize)
      }
      if result == 0 {
        guard readSize > 0 else { return nil }
        return Array(buffer.prefix(min(readSize, buffer.count)))
      }
      guard errno == ENOMEM || readSize > size else { return nil }
      size = max(readSize, size * 2)
    }

    return nil
  }

  private static func sysctlProcargs2(
    _ mib: inout [Int32],
    buffer: UnsafeMutableRawPointer?,
    size: inout Int
  ) -> Int32 {
    var result: Int32
    repeat {
      errno = 0
      result = sysctl(&mib, u_int(mib.count), buffer, &size, nil, 0)
    } while result == -1 && errno == EINTR
    return result
  }

  static func procargs2Argv(_ buffer: [UInt8]) -> [String]? {
    guard buffer.count >= MemoryLayout<Int32>.size else { return nil }
    let argc = buffer.withUnsafeBytes { rawBuffer in
      rawBuffer.loadUnaligned(as: Int32.self)
    }
    guard argc > 0 else { return nil }

    var position = MemoryLayout<Int32>.size
    guard let execEnd = buffer[position...].firstIndex(of: 0) else { return nil }
    position = execEnd
    while position < buffer.count, buffer[position] == 0 {
      position += 1
    }

    var argv: [String] = []
    while position < buffer.count, argv.count < Int(argc) {
      let start = position
      while position < buffer.count, buffer[position] != 0 {
        position += 1
      }
      guard position < buffer.count,
        let value = String(bytes: buffer[start..<position], encoding: .utf8)
      else {
        return nil
      }
      argv.append(value)
      position += 1
    }

    return argv.count == Int(argc) ? argv : nil
  }
}
