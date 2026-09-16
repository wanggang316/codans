import Foundation
import SQLite3

/// A single transaction persists each state transition together with its event history.
@MainActor final class WorkflowDatabaseV2 {
  private var database: OpaquePointer?
  let root: URL

  init(root: URL) throws {
    self.root = root
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    guard sqlite3_open(root.appendingPathComponent("runs.sqlite").path, &database) == SQLITE_OK
    else {
      throw WorkflowRuntimeErrorV2.invalid("Cannot open workflow database")
    }
    try execute(
      "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, snapshot BLOB NOT NULL);"
    )
  }

  isolated deinit { sqlite3_close(database) }

  func load() throws -> [WorkflowRunV2] {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, "SELECT snapshot FROM runs", -1, &statement, nil) == SQLITE_OK
    else { throw failure() }
    defer { sqlite3_finalize(statement) }
    var result: [WorkflowRunV2] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
        throw failure()
      }
      let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
      result.append(try JSONDecoder().decode(WorkflowRunV2.self, from: data))
    }
    return result
  }

  func save(_ run: WorkflowRunV2) throws {
    let data = try JSONEncoder().encode(run)
    guard data.count <= 16 * 1024 * 1024 else {
      throw WorkflowRuntimeErrorV2.invalid("Workflow record exceeds 16 MiB")
    }
    try execute("BEGIN IMMEDIATE")
    do {
      var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
          database, "INSERT OR REPLACE INTO runs (id, snapshot) VALUES (?, ?)", -1, &statement, nil)
          == SQLITE_OK
      else { throw failure() }
      defer { sqlite3_finalize(statement) }
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      guard sqlite3_bind_text(statement, 1, run.id.uuidString, -1, transient) == SQLITE_OK else {
        throw failure()
      }
      let bound = data.withUnsafeBytes {
        sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient)
      }
      guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func execute(_ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
  }

  private func failure() -> WorkflowRuntimeErrorV2 {
    .invalid("Workflow persistence failed: \(String(cString: sqlite3_errmsg(database)))")
  }
}
