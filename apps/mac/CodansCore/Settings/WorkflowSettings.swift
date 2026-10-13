import Foundation

/// `settings.json` → `workflows`: the machine-local side of Agent Workflows.
/// A workflow file declares abstract roles and stays portable; everything
/// that ties it to *this* machine — which profile plays a role, which
/// repository files the user has agreed to run, which definitions are
/// switched off — lives here, keyed by workflow id and scope rather than
/// by file contents.
public nonisolated struct WorkflowSettings: Equatable, Codable, Sendable {
  /// Master switch. Off makes every `workflow.*` IPC method `unsupported`
  /// and hides the GUI entry points; nothing else in the app changes.
  public var isEnabled: Bool
  /// Workflow ids the user turned off in Settings. A disabled definition
  /// stays listed (with its diagnostics) but cannot start.
  public var disabled: Set<String>
  /// Remembered `launch` role → profile choices.
  public var bindings: [WorkflowBindingMemory]
  /// Repository-scoped files with `run:` steps the user agreed to execute.
  public var trusted: [WorkflowTrustGrant]

  public init(
    isEnabled: Bool = true,
    disabled: Set<String> = [],
    bindings: [WorkflowBindingMemory] = [],
    trusted: [WorkflowTrustGrant] = []
  ) {
    self.isEnabled = isEnabled
    self.disabled = disabled
    self.bindings = bindings
    self.trusted = trusted
  }

  public static let `default` = WorkflowSettings()

  public func isDisabled(_ workflowID: String) -> Bool {
    disabled.contains(workflowID)
  }

  public func binding(scope: WorkflowBindingMemory.Scope, workflowID: String, role: String, digest: String)
    -> WorkflowBindingMemory?
  {
    bindings.first {
      $0.scope == scope && $0.workflowID == workflowID && $0.role == role && $0.requirementsDigest == digest
    }
  }

  /// Replaces any earlier memory for the same `(scope, workflow, role)`;
  /// a role has one remembered profile at a time.
  public mutating func remember(_ memory: WorkflowBindingMemory) {
    bindings.removeAll {
      $0.scope == memory.scope && $0.workflowID == memory.workflowID && $0.role == memory.role
    }
    bindings.append(memory)
  }

  public mutating func forgetBinding(scope: WorkflowBindingMemory.Scope, workflowID: String, role: String) {
    bindings.removeAll { $0.scope == scope && $0.workflowID == workflowID && $0.role == role }
  }

  public func isTrusted(path: String, sha256: String) -> Bool {
    trusted.contains { $0.path == path && $0.sha256 == sha256 }
  }

  /// One grant per path: re-trusting an edited file replaces the stale one.
  public mutating func trust(path: String, sha256: String, at date: Date) {
    trusted.removeAll { $0.path == path }
    trusted.append(WorkflowTrustGrant(path: path, sha256: sha256, grantedAt: date))
  }

  public mutating func revokeTrust(path: String) {
    trusted.removeAll { $0.path == path }
  }

  private enum CodingKeys: String, CodingKey {
    case isEnabled = "enabled"
    case disabled
    case bindings
    case trusted
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    self.disabled = Set(try container.decodeIfPresent([String].self, forKey: .disabled) ?? [])
    self.bindings = try container.decodeIfPresent([WorkflowBindingMemory].self, forKey: .bindings) ?? []
    self.trusted = try container.decodeIfPresent([WorkflowTrustGrant].self, forKey: .trusted) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if !isEnabled { try container.encode(isEnabled, forKey: .isEnabled) }
    if !disabled.isEmpty { try container.encode(disabled.sorted(), forKey: .disabled) }
    if !bindings.isEmpty { try container.encode(bindings, forKey: .bindings) }
    if !trusted.isEmpty { try container.encode(trusted, forKey: .trusted) }
  }

  /// `true` when nothing differs from the defaults, so `settings.json`
  /// can omit the subtree entirely.
  public var isDefault: Bool { self == .default }
}

/// A remembered `launch` role binding. `requirementsDigest` hashes the
/// role's requirement block (`source`, `agents`, `profile`) so that editing
/// what the role asks for invalidates the memory while a prompt-only edit
/// keeps it.
public nonisolated struct WorkflowBindingMemory: Equatable, Codable, Sendable {
  public typealias Scope = WorkflowScope

  public var scope: Scope
  public var workflowID: String
  public var role: String
  public var requirementsDigest: String
  public var profileID: UUID

  public init(scope: Scope, workflowID: String, role: String, requirementsDigest: String, profileID: UUID) {
    self.scope = scope
    self.workflowID = workflowID
    self.role = role
    self.requirementsDigest = requirementsDigest
    self.profileID = profileID
  }

  private enum CodingKeys: String, CodingKey {
    case scope
    case workflowID = "workflow"
    case role
    case requirementsDigest = "digest"
    case profileID = "profile"
  }
}

/// The user's one-time agreement to run the `run:` steps of a
/// repository-scoped workflow file. Bound to the file's content hash: any
/// edit needs a new grant.
public nonisolated struct WorkflowTrustGrant: Equatable, Codable, Sendable {
  public var path: String
  public var sha256: String
  public var grantedAt: Date

  public init(path: String, sha256: String, grantedAt: Date) {
    self.path = path
    self.sha256 = sha256
    self.grantedAt = grantedAt
  }
}
