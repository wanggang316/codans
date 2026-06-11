import Foundation
import CodansCore

// C8a Phase 4c wire types. Matches the NSWorkspace-backed descriptor shape from
// `docs/design-docs/c8a-editor-integration-nsworkspace.md`: bundle identifier, launch mode,
// resolved app URL. No `argv`, no `CommandTemplate`, no `InstallationStatusDTO` — a missing
// entry IS the "not installed" signal.

/// Wire payload for a single entry in the `editor.describe` response. Mirrors the app-tier
/// `EditorDescriptor` with `Codable` fields only; kept parallel (rather than re-exported)
/// so the IPC module never imports the app-tier target.
public nonisolated struct EditorDescriptorDTO: Equatable, Hashable, Codable, Sendable, Identifiable {
  /// Matches `EditorDescriptor.LaunchMode` — string-encoded for cross-module wire stability.
  public enum LaunchModeDTO: String, Equatable, Hashable, Codable, Sendable {
    case directory
    case applicationWithArguments
    case shellEditor
  }

  public var id: EditorID
  public var displayName: String
  /// Launch Services bundle identifier. Empty for `.shellEditor`.
  public var bundleIdentifier: String
  public var launchMode: LaunchModeDTO
  /// Resolved `.app` URL from Launch Services. `nil` for `.shellEditor`.
  public var appURL: URL?
  public var alternateBundleIdentifiers: [String]

  public init(
    id: EditorID,
    displayName: String,
    bundleIdentifier: String,
    launchMode: LaunchModeDTO,
    appURL: URL?,
    alternateBundleIdentifiers: [String] = []
  ) {
    self.id = id
    self.displayName = displayName
    self.bundleIdentifier = bundleIdentifier
    self.launchMode = launchMode
    self.appURL = appURL
    self.alternateBundleIdentifiers = alternateBundleIdentifiers
  }
}

/// Wire payload for the `editor.open` response choice. `argv` is gone in C8a — NSWorkspace
/// launches have no argv to expose.
public nonisolated struct EditorChoiceDTO: Equatable, Hashable, Codable, Sendable {
  public var id: EditorID
  public var displayName: String
  /// Optional binary path. Absent for NSWorkspace launches; populated only for `.shellEditor`
  /// where the Pane's shell resolves `$EDITOR`.
  public var binaryPath: String?

  public init(id: EditorID, displayName: String, binaryPath: String? = nil) {
    self.id = id
    self.displayName = displayName
    self.binaryPath = binaryPath
  }
}

// MARK: - Request / Response envelopes

public nonisolated struct EditorDescribeResponse: Equatable, Codable, Sendable {
  public var descriptors: [EditorDescriptorDTO]

  public init(descriptors: [EditorDescriptorDTO]) {
    self.descriptors = descriptors
  }
}

/// `editor.open` request. `path` is mandatory — callers (including the CLI) resolve their own
/// context to an absolute directory path before dispatching. `preferred` is optional and, when
/// set, is treated strictly (uninstalled → error); when nil, the handler performs the per-Project
/// override lookup and, failing that, the service cascades through global default → priority walk
/// → Finder.
public nonisolated struct EditorOpenRequest: Equatable, Codable, Sendable {
  public var path: String
  public var preferred: EditorID?

  public init(path: String, preferred: EditorID? = nil) {
    self.path = path
    self.preferred = preferred
  }
}

public nonisolated struct EditorOpenResponse: Equatable, Codable, Sendable {
  public var choice: EditorChoiceDTO

  public init(choice: EditorChoiceDTO) {
    self.choice = choice
  }
}

/// `editor.setGlobalDefault` — writes `settings.general.defaultEditorID`. `nil` clears.
public nonisolated struct EditorSetGlobalDefaultRequest: Equatable, Codable, Sendable {
  public var editorID: EditorID?

  public init(editorID: EditorID?) {
    self.editorID = editorID
  }
}

public nonisolated struct EditorSetGlobalDefaultResponse: Equatable, Codable, Sendable {
  public init() {}
}

/// `editor.setProjectDefault` — writes `Settings.projects[pid].defaultEditor` via
/// `SettingsStore.mutateProject`. `nil` clears the override.
public nonisolated struct EditorSetProjectDefaultRequest: Equatable, Codable, Sendable {
  public var projectID: UUID
  public var editorID: EditorID?

  public init(projectID: UUID, editorID: EditorID?) {
    self.projectID = projectID
    self.editorID = editorID
  }
}

public nonisolated struct EditorSetProjectDefaultResponse: Equatable, Codable, Sendable {
  public init() {}
}
