import Foundation

/// The OSC 7501 records of one terminal (one pane), with the lifetime rules
/// of the protocol: one record per id, a report replaces its record whole,
/// `clear` removes a subtree (no id: everything), and the least recently
/// updated record is evicted when the table is full.
///
/// Records belong to the terminal, not to a surface: a pane keeps them
/// across surface reclaim and re-attach. The owner drops the live records
/// (`dropLiveRecords`) when the reporting program is gone, because the
/// protocol has no heartbeat.
public nonisolated struct ProgramStatusRecords: Sendable, Equatable {
  /// One stored record. `app` is the record's own value; the summary
  /// resolves inheritance.
  public struct Record: Sendable, Equatable {
    public var state: ProgramStatusState
    public var kind: ProgramStatusKind?
    public var progress: Int?
    public var app: String?
    public var title: String?
    public var message: String?
  }

  /// The protocol caps a terminal at 256 records.
  public static let capacity = 256

  private var records: [String: Record] = [:]
  private var updatedAt: [String: UInt64] = [:]
  private var clock: UInt64 = 0

  public init() {}

  public var isEmpty: Bool { records.isEmpty }
  public var count: Int { records.count }

  /// Apply one report. Returns whether the stored records changed.
  @discardableResult
  public mutating func apply(_ report: ProgramStatusReport) -> Bool {
    if report.state == .clear {
      return remove { id in
        report.id.isEmpty || id == report.id || id.hasPrefix(report.id + "/")
      }
    }
    let record = Record(
      state: report.state,
      kind: report.kind,
      progress: report.progress,
      app: report.app,
      title: report.title,
      message: report.message
    )
    clock += 1
    updatedAt[report.id] = clock
    guard records[report.id] != record else { return false }
    records[report.id] = record
    evictIfNeeded()
    return true
  }

  /// Drop `working`, `blocked` and `idle` records: the program that sent
  /// them is gone. `done` and `error` stay until a new report replaces them.
  @discardableResult
  public mutating func dropLiveRecords() -> Bool {
    let current = records
    return remove { id in
      guard let state = current[id]?.state else { return false }
      return state == .working || state == .blocked || state == .idle
    }
  }

  public var summary: ProgramStatusSummary? {
    guard !records.isEmpty else { return nil }
    let root = records[""].map { resolved($0, id: "") }
    let rootApp = root?.app
    let blockedChild =
      records
      .filter { $0.key != "" && $0.value.state == .blocked }
      .map { (id: $0.key, record: resolved($0.value, id: $0.key)) }
      .filter { $0.record.app == rootApp }
      .max { (updatedAt[$0.id] ?? 0) < (updatedAt[$1.id] ?? 0) }?
      .record
    return ProgramStatusSummary(root: root, blockedChild: blockedChild)
  }

  /// `record` with its `app` inherited from the nearest ancestor that has one.
  private func resolved(_ record: Record, id: String) -> Record {
    var result = record
    var cursor = id
    while result.app == nil, !cursor.isEmpty {
      cursor = cursor.lastIndex(of: "/").map { String(cursor[..<$0]) } ?? ""
      result.app = records[cursor]?.app
    }
    return result
  }

  private mutating func remove(where shouldRemove: (String) -> Bool) -> Bool {
    let doomed = records.keys.filter(shouldRemove)
    for id in doomed {
      records.removeValue(forKey: id)
      updatedAt.removeValue(forKey: id)
    }
    return !doomed.isEmpty
  }

  private mutating func evictIfNeeded() {
    while records.count > Self.capacity,
      let oldest = updatedAt.min(by: { $0.value < $1.value })?.key
    {
      records.removeValue(forKey: oldest)
      updatedAt.removeValue(forKey: oldest)
    }
  }
}

/// What a pane's records say, reduced to what agent state needs. The pane
/// follows its root record. A blocked child also blocks the pane, but a
/// working child does not keep it working: background work must not hold a
/// pane busy.
public nonisolated struct ProgramStatusSummary: Sendable, Equatable {
  public typealias Record = ProgramStatusRecords.Record

  /// The root record with its effective `app`, nil if the program sent none.
  public var root: Record?
  /// The most recently updated blocked child of the same app as the root.
  public var blockedChild: Record?

  public init(root: Record?, blockedChild: Record?) {
    self.root = root
    self.blockedChild = blockedChild
  }

  /// The state the pane should show, nil without a root record.
  public var activity: Record? {
    guard let root else { return nil }
    if root.state != .blocked, let blockedChild {
      return blockedChild
    }
    return root
  }

  /// Whether these records decide the state of a pane bound to `kind`. The
  /// root must come from that agent (`app` matches its adapter), so another
  /// program's reports in the same terminal cannot steer the agent's state.
  public func governs(_ kind: AgentKind?) -> Bool {
    guard let kind, let root, let app = root.app else { return false }
    return AgentRuntimeAdapters.adapter(for: kind).programStatusApp == app
  }
}
