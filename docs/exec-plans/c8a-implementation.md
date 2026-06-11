# Execution Plan: Editor Integration NSWorkspace Rewrite (C8a)

**Design Doc:** [c8a-editor-integration-nsworkspace.md](../design-docs/c8a-editor-integration-nsworkspace.md)

**Scope:** Replace C8's PATH-based Process spawning with NSWorkspace + Launch Services discovery. Deliver a curated 28-entry editor registry with correct macOS app detection regardless of CLI-shim installation.

**Key Constraint:** C8a's `.editor` case depends on a Pane primitive: "create Pane at path with initial stdin input `$EDITOR\n`". If this primitive doesn't exist, drop `.editor` from this iteration (one-line registry change) and defer to a follow-up when the Pane side is ready.

---

## Context and Orientation

**Specification:** [product-spec.md](../product-spec.md) — "Worktree-level directory open, driven by dropdown or `codans open` CLI."

**Related Design Docs:**
- [c8-editor-integration.md](../design-docs/c8-editor-integration.md) — Previous design (now superseded).
- [c8a-editor-integration-nsworkspace.md](../design-docs/c8a-editor-integration-nsworkspace.md) — This plan's full rationale, trade-offs, and specifications.

**Architecture Context:** [docs/architecture.md](../architecture.md) — Tuist monorepo, in-app modules under `codans/App/`, folder-level boundaries between Runtime/Hooks/Git/App.

**Key Existing Code Paths:**
- **EditorService** — `apps/mac/codans/App/Clients/Editor/{EditorService.swift, EditorService+Live.swift, EditorService+Test.swift}`
- **Registry** — `apps/mac/codans/App/Clients/Editor/EditorRegistry.swift`
- **Models** — `apps/mac/codans/App/Clients/Editor/EditorModels.swift`
- **IPC Handlers** — `apps/mac/codans/App/Features/Socket/EditorHandlers.swift`
- **Settings UI** — `apps/mac/codans/App/Features/Settings/Panes/` (add new pane for editor default)
- **Project Options** — `apps/mac/codans/App/Features/Settings/RepositorySettingsFeature.swift`
- **Pane spawning** — `apps/mac/codans/Runtime/Pane*.swift` (verify `.editor` spawn capability)

**Deliverables:**
1. 28-entry built-in registry with bundle IDs, display names, and launch modes.
2. `AppLauncher` protocol — macOS LS/NSWorkspace abstraction.
3. Refactored `EditorService` — resolution cascade (strict preferred → lenient defaults → auto-pick → Finder).
4. Settings "Default editor" pane — installed-only dropdown with real `.app` icons.
5. Project Options "Editor" override — per-project picker via `HierarchyClient`.
6. IPC handlers — `editor.describe`, `editor.open`, `editor.setGlobalDefault`, `editor.setProjectDefault`.
7. Migration logic — silently normalize stale `defaultEditorID` and drop `customEditors`.
8. Tests — registry sanity, resolution cascade, JetBrains launch args, migration edge cases.

---

## Key Interfaces and Dependencies

### AppLauncher Protocol

```swift
protocol AppLauncher: Sendable {
  /// Resolve a bundle identifier to an app URL, or nil if not installed.
  func urlForApplication(bundleIdentifier: String) -> URL?
  
  /// Launch one or more directory URLs in the specified app.
  /// Uses NSWorkspace.open(urls:withApplicationAt:configuration:).
  func open(urls: [URL], withApplicationAt appURL: URL,
            configuration: NSWorkspace.OpenConfiguration) async throws
}
```

**Live implementation:** Wraps `NSWorkspace.shared`. Imports `Foundation` only.

**Test double:** `RecordingAppLauncher` — takes `(bundleID → URL, appURL → launch result)` dictionaries; verifies calls match expectations.

### EditorDescriptor

```swift
struct EditorDescriptor: Identifiable, Equatable, Sendable {
  let id: EditorID
  let displayName: String
  let bundleIdentifier: String  // empty for .shellEditor
  let launchMode: LaunchMode
  let appURL: URL?              // nil for .shellEditor; otherwise resolved from LS
  
  enum LaunchMode: Equatable, Sendable {
    case directory
    case applicationWithArguments
    case shellEditor
  }
}
```

### EditorService

```swift
protocol EditorService: Sendable {
  func describe() async -> [EditorDescriptor]  // installed only
  func resolve(preferred: EditorID?) async -> EditorDescriptor
  @discardableResult
  func open(directory: URL, preferred: EditorID?) async throws -> EditorChoice
}
```

No change to signature; semantics simplified (describe returns installed-only; open removes argv).

### EditorRegistry

```swift
static let registry: [EditorDescriptor] = [
  EditorDescriptor(id: "cursor", displayName: "Cursor", 
                   bundleIdentifier: "com.todesktop.230313mzl4w4u92", 
                   launchMode: .directory, appURL: nil),
  // ... 27 more entries
]

static let editorPriority: [EditorID] = ["cursor", "zed", "vscode", ...]
static let terminalPriority: [EditorID] = ["ghostty", "wezterm", ...]
static let gitClientPriority: [EditorID] = ["githubDesktop", "sourcetree", ...]
static let defaultPriority: [EditorID] = 
  editorPriority + ["xcode", "finder"] + terminalPriority + gitClientPriority
static let menuOrder: [EditorID] = 
  editorPriority + ["xcode"] + ["finder"] + terminalPriority + gitClientPriority + ["editor"]
```

All 28 entries from the design doc, with exact bundle IDs.

### IPC Changes

```swift
// editor.describe → [EditorDescriptor]
// Payload shape: id, displayName, bundleIdentifier, launchMode, appURL
// No argv field.

// editor.open { path: String, preferred?: EditorID } → EditorChoice
// path must be absolute directory; preferred optional.
// Handler does: hierarchyClient.project(containing: path)?.defaultEditor 
//               and passes result as preferred if installed.

// editor.setGlobalDefault { editorID? } → void
// Sets settings.general.defaultEditorID

// editor.setProjectDefault { projectID: UUID, editorID? } → void
// Writes project.defaultEditor via HierarchyClient.setRepositoryDefaultEditor
```

### HierarchyClient Integration

The IPC handler imports `HierarchyClient` to:
- Reverse-lookup the Project containing a given directory path.
- Read the Project's `defaultEditor` override (if any).
- Write `setRepositoryDefaultEditor(projectID, editorID)` when Project Options commits.

Service itself never sees `HierarchyClient` or domain types — only the IPC handler bridges them.

### SettingsStore Fields

```swift
struct GeneralSettings: Codable {
  var defaultEditorID: EditorID? = nil  // was: builtin or custom; now: builtin only
  // customEditors removed from runtime (decode tolerantly)
}
```

Project model:
```swift
struct Project {
  var defaultEditor: EditorID? = nil  // kept; value domain narrows to built-in IDs
}
```

---

## Plan of Work

### Phase 1: Verification & Groundwork (parallel)

**Task 1.1: Pane `.editor` spawn capability check**

Verify that the Pane primitive exists: "create Pane at path with initial stdin input `$EDITOR\n`".

*Outcome:* Document whether the capability exists today or must be built. If doesn't exist, flag for Phase 2 decision (drop `.editor` from registry vs. build the primitive).

*Verification:*
- Read `apps/mac/codans/Runtime/Pane*.swift` to understand Pane creation and stdin routing.
- Check if there's already a method like `Pane.create(at: URL, initialInput: String)` or equivalent.
- If missing, estimate effort to add it; flag as a blocker for C8a `.editor` delivery.

**Task 1.2: Review existing SettingsStore + Project models**

Understand the current storage structure so migration logic is precise.

*Outcome:* Identify all places `customEditors` is referenced; map Project model fields.

*Verification:*
- Read `apps/mac/codans/App/Features/Settings/SettingsStore.swift`.
- Confirm where `customEditors` array is stored and decoded.
- Confirm Project's `defaultEditor` field exists.
- Identify where settings are loaded at startup.

**Task 1.3: HierarchyClient API contract review**

Understand how to reverse-lookup a Project from a directory path and how to write overrides.

*Outcome:* Document the two methods: `project(containing: URL) -> Project?` and `setRepositoryDefaultEditor(UUID, EditorID?)`.

*Verification:*
- Read or grep for `HierarchyClient.swift` or `HierarchyFeature.swift`.
- Confirm method signatures and return types.
- Identify where this client is wired as a dependency.

---

### Phase 2: Core Infrastructure (mostly independent; can start after Phase 1)

**Task 2.1: Create EditorRegistry.swift**

Define the static 28-entry registry with all bundle IDs, display names, and launch modes.

*Outcome:* `EditorRegistry.swift` with:
- `static let registry: [EditorDescriptor]` — all 28 entries, each with exact bundle ID from the design doc.
- `static let editorPriority`, `terminalPriority`, `gitClientPriority`, `defaultPriority`, `menuOrder`.
- Table-driven design — no hardcoded fallbacks.

*Verification:*
- Compile without errors.
- Run a table-driven test: `registry.count == 28`, all IDs unique, all bundle IDs non-empty except `.shellEditor`.
- Spot-check 3–4 entries: `cursor` → `com.todesktop.230313mzl4w4u92`, `vscode` → `com.microsoft.VSCode`, `.editor` → empty bundleID, `.editor` → `.shellEditor` launch mode.

*Files modified:*
- `apps/mac/codans/App/Clients/Editor/EditorRegistry.swift` — replace entire file.

---

**Task 2.2: Update EditorModels.swift**

Add `LaunchMode` enum; update `EditorDescriptor` and `EditorChoice` shapes.

*Outcome:* 
- `enum LaunchMode: Equatable, Sendable { case directory; case applicationWithArguments; case shellEditor }`.
- `EditorDescriptor` gains `launchMode: LaunchMode`, `appURL: URL?` (nil for `.shellEditor`).
- `EditorChoice` loses `argv: [String]` field.
- Both `Codable` or `Sendable` as needed.

*Verification:*
- Compile without errors.
- Snapshot test: encode/decode an `EditorDescriptor` to JSON, verify shape matches design doc.
- Confirm no code outside EditorModels references the removed `argv` field (should find zero matches if we're following the plan).

*Files modified:*
- `apps/mac/codans/App/Clients/Editor/EditorModels.swift` — update shapes.

---

**Task 2.3: Create AppLauncher.swift**

Define the NSWorkspace abstraction protocol and live implementation.

*Outcome:* 
- `protocol AppLauncher: Sendable` with two methods: `urlForApplication(bundleIdentifier:)` and `open(urls:withApplicationAt:configuration:)`.
- `struct LiveAppLauncher: AppLauncher` — wraps `NSWorkspace.shared`, no caching.

*Verification:*
- Compile without errors.
- Quick smoke test: `LiveAppLauncher().urlForApplication(bundleIdentifier: "com.apple.finder")` returns a non-nil URL at runtime.

*Files created:*
- `apps/mac/codans/App/Clients/Editor/AppLauncher.swift`.

---

**Task 2.4: Create EditorError.swift updates**

Simplify error cases to three: `.notInstalled`, `.launchFailed`, `.notADirectory`.

*Outcome:*
```swift
enum EditorError: LocalizedError {
  case notInstalled(id: EditorID, bundleID: String)
  case launchFailed(reason: String)
  case notADirectory(path: String)
}
```

Remove: `.nonZeroExit`, `.timedOut`, `.spawnFailed`, `.badTemplate`, `.unresolvedWorktree`.

*Verification:*
- Compile without errors.
- Grep `EditorError` across the codebase; verify no code references removed cases (should find zero if old code is deleted).

*Files modified:*
- `apps/mac/codans/App/Clients/Editor/EditorError.swift` — replace entire file.

---

### Phase 3: Service Refactor (depends on Phase 2)

**Task 3.1: Rewrite EditorService+Live.swift**

Core logic: resolution cascade + app detection + launch branching.

*Outcome:* Implement `LiveEditorService`:

```swift
struct LiveEditorService: EditorService {
  private let launcher: AppLauncher
  private let settingsStore: SettingsStore
  private var cachedDescriptors: [EditorDescriptor]? = nil
  
  func describe() async -> [EditorDescriptor] {
    // Probe all registry entries via launcher; cache result.
    // Return only entries with non-nil appURL or .shellEditor.
  }
  
  func resolve(preferred: EditorID?) async -> EditorDescriptor {
    let all = await describe()  // installed only
    
    // Cascade:
    if let preferred = preferred {
      guard let desc = all.first(where: { $0.id == preferred }) else {
        throw EditorError.notInstalled(id: preferred, bundleID: ???)
      }
      return desc
    }
    
    // Skip to global default
    if let defaultID = settingsStore.general.defaultEditorID,
       let desc = all.first(where: { $0.id == defaultID }) {
      return desc
    }
    
    // Auto-pick from priority list
    let priority = EditorRegistry.defaultPriority
    for id in priority {
      if let desc = all.first(where: { $0.id == id }) {
        return desc
      }
    }
    
    // Always terminates at Finder
    return all.first(where: { $0.id == "finder" })!
  }
  
  func open(directory: URL, preferred: EditorID?) async throws -> EditorChoice {
    guard FileManager.default.fileExists(atPath: directory.path),
          ... else {
      throw EditorError.notADirectory(path: directory.path)
    }
    
    let resolved = await resolve(preferred: preferred)
    
    switch resolved.launchMode {
    case .directory:
      try await launcher.open(urls: [directory], withApplicationAt: resolved.appURL!, 
                              configuration: NSWorkspace.OpenConfiguration())
    case .applicationWithArguments:
      var config = NSWorkspace.OpenConfiguration()
      config.arguments = [directory.path]
      config.createsNewApplicationInstance = true
      try await launcher.open(urls: [], withApplicationAt: resolved.appURL!, configuration: config)
    case .shellEditor:
      // Create Pane at directory, send "$EDITOR\n" to stdin.
      // Requires the Pane primitive from Task 1.1.
      // If not available, this branch throws .launchFailed.
    }
    
    return EditorChoice(id: resolved.id, displayName: resolved.displayName, binaryPath: nil)
  }
}
```

*Key implementation notes:*
- `describe()` caches results; can be called repeatedly without re-probing.
- `resolve()` does NOT update the cache; that's done elsewhere (Settings pane appear, IPC call).
- `open()` does NOT spawn a Pane directly for `.shellEditor` — it delegates to the Pane primitive. If that primitive doesn't exist, throw `.launchFailed("Pane primitive not available")`.

*Verification:*
- Unit tests (see Task 5.1).
- Compile without errors.
- Integration smoke test (gated by env var): actually open a temp directory in Finder via NSWorkspace.

*Files modified:*
- `apps/mac/codans/App/Clients/Editor/EditorService+Live.swift` — replace entire file.

---

**Task 3.2: Rewrite EditorService+Test.swift**

Create a test double that records calls and allows injection of expected results.

*Outcome:* `MockEditorService` or `TestEditorService`:

```swift
struct TestEditorService: EditorService {
  var describedDescriptors: [EditorDescriptor] = []
  var resolveResult: EditorDescriptor?
  var openShouldThrow: EditorError?
  
  func describe() async -> [EditorDescriptor] { describedDescriptors }
  func resolve(preferred: EditorID?) async -> EditorDescriptor { resolveResult! }
  func open(directory: URL, preferred: EditorID?) async throws -> EditorChoice { 
    if let err = openShouldThrow { throw err }
    return EditorChoice(id: "test", displayName: "Test", binaryPath: nil)
  }
}
```

*Verification:*
- Compile without errors.
- Can be instantiated and used in TCA tests.

*Files modified:*
- `apps/mac/codans/App/Clients/Editor/EditorService+Test.swift` — replace entire file.

---

**Task 3.3: Delete obsolete files**

Remove Process, PathProber, SpawnContract, EditorEnv, and custom-editor types.

*Outcome:* Files deleted:
- `apps/mac/codans/App/Clients/Editor/PathProber.swift`
- `apps/mac/codans/App/Clients/Editor/ProcessSpawner.swift`
- `apps/mac/codans/App/Clients/Editor/SpawnContract.swift`
- `apps/mac/codans/App/Clients/Editor/EditorEnv.swift`

Remove from `EditorModels.swift`:
- `CustomEditor` type
- `CommandTemplate` type
- `EditorTemplateError` type

*Verification:*
- Build succeeds (no references to deleted files).
- Tests still pass (test doubles no longer reference Process).

---

### Phase 4: UX Layers (depends on Phase 3)

**Task 4.1: Settings "Default editor" pane**

Create a new Settings pane showing installed editors in a dropdown.

*Outcome:* New view `GeneralEditorSettingsView` (or similar):

```swift
struct GeneralEditorSettingsView: View {
  @Dependency(\.editorService) var editorService
  @State var descriptors: [EditorDescriptor] = []
  @State var selectedID: EditorID? = nil
  
  var body: some View {
    Form {
      Section("Default editor") {
        Picker("", selection: $selectedID) {
          ForEach(descriptors) { desc in
            HStack {
              Image(nsImage: NSWorkspace.shared.icon(forFile: desc.appURL!.path))
                .resizable()
                .frame(width: 16, height: 16)
              Text(desc.displayName)
            }
            .tag(desc.id as EditorID?)
          }
        }
        Text("Used when opening a directory. Falls back to Finder if the chosen editor is uninstalled later.")
          .font(.caption)
      }
    }
    .task {
      descriptors = await editorService.describe()
    }
    .onChange(of: selectedID) { _, newID in
      settingsStore.general.defaultEditorID = newID
    }
  }
}
```

Category separators between editor / xcode+finder / terminal / git-client / `.editor` groups.

*Verification:*
- Compile without errors.
- Preview: snapshot with 0 editors (only Finder), few editors (VSCode + Cursor + Finder), many editors (all 28).
- Verify icons are non-nil and visible.

*Files created/modified:*
- `apps/mac/codans/App/Features/Settings/Panes/GeneralEditorSettingsView.swift` — new.
- Update `SettingsWindowView.swift` or similar to include this pane in the "General" section.

---

**Task 4.2: Project Options "Editor" override**

Add a per-project editor picker in the Project Options sheet.

*Outcome:* New picker view in `RepositorySettingsFeature`:

```swift
Section("Editor") {
  Picker("Open in", selection: $projectDefaultEditorID) {
    Label("↩ Use global default", systemImage: "return")
      .tag(nil as EditorID?)
    
    Divider()
    
    ForEach(descriptors) { desc in
      HStack {
        Image(nsImage: NSWorkspace.shared.icon(forFile: desc.appURL!.path))
          .resizable()
          .frame(width: 16, height: 16)
        Text(desc.displayName)
      }
      .tag(desc.id as EditorID?)
    }
  }
}
.onChange(of: projectDefaultEditorID) { _, newID in
  // Dispatch IPC: editor.setProjectDefault { projectID, newID }
  // Or call HierarchyClient.setRepositoryDefaultEditor(projectID, newID)
}
```

*Verification:*
- Compile without errors.
- Preview: confirm "↩ Use global default" is the first option, followed by installed editors.

*Files modified:*
- `apps/mac/codans/App/Features/Settings/RepositorySettingsFeature.swift` — add Editor section.

---

**Task 4.3: Update IPC handlers (EditorHandlers.swift)**

Implement the four RPC methods: `editor.describe`, `editor.open`, `editor.setGlobalDefault`, `editor.setProjectDefault`.

*Outcome:* 

```swift
// editor.describe
case .editorDescribe:
  let descriptors = await editorService.describe()
  send(Response(descriptors: descriptors))

// editor.open
case .editorOpen(let request):
  let directory = URL(fileURLWithPath: request.path)
  var preferred = request.preferred
  
  // Check for project override
  if preferred == nil,
     let project = await hierarchyClient.project(containing: directory),
     let projDefault = project.defaultEditor,
     let installed = await editorService.describe().first(where: { $0.id == projDefault }) {
    preferred = projDefault
  }
  
  let choice = try await editorService.open(directory: directory, preferred: preferred)
  send(Response(choice: choice))

// editor.setGlobalDefault
case .editorSetGlobalDefault(let editorID):
  settingsStore.general.defaultEditorID = editorID
  send(Response.ok)

// editor.setProjectDefault
case .editorSetProjectDefault(let projectID, let editorID):
  try await hierarchyClient.setRepositoryDefaultEditor(projectID, editorID)
  send(Response.ok)
```

The key pattern: caller pre-filters the project default if installed; service never sees ProjectID.

*Verification:*
- Compile without errors.
- Integration test: send IPC request, verify response shape matches design doc.

*Files modified:*
- `apps/mac/codans/App/Features/Socket/EditorHandlers.swift` — replace entire file.

---

**Task 4.4: Update IPC wire types**

Ensure `CodansIPC/Editor/` types match the new shapes.

*Outcome:* 
- Remove `argv: [String]` from `EditorChoicePayload`.
- Add `launchMode` and `appURL?` to `EditorDescriptorPayload`.
- Add new RPC methods: `editor.setGlobalDefault`, `editor.setProjectDefault`.

*Verification:*
- Compile without errors.
- Round-trip test: encode an `EditorDescriptor`, decode it, verify fields match.

*Files modified:*
- `apps/mac/CodansIPC/Editor/` (if it exists) or update the IPC definitions wherever they live.

---

### Phase 5: Integration & Migration (depends on Phase 4)

**Task 5.1: Migration at startup**

Implement the tolerance-on-decode + normalization logic.

*Outcome:* In `SettingsStore` load or `EditorService` init:

```swift
private func migrateSettings() {
  // 1. Ignore customEditors if present
  let customEditors = try? JSONDecoder().decode([CustomEditor].self, from: customEditorsData)
  if customEditors?.isEmpty == false {
    logger.info("Loaded legacy customEditors; ignoring (C8a uses built-in registry only)")
  }
  
  // 2. Normalize stale defaultEditorID
  if let storedID = settings.general.defaultEditorID,
     !EditorRegistry.registry.contains(where: { $0.id == storedID }) {
    logger.info("Stale defaultEditorID '\(storedID)' not in built-in registry; resetting to nil")
    settings.general.defaultEditorID = nil
  }
  
  // 3. Normalize stale Project.defaultEditor values
  for project in projects {
    if let storedID = project.defaultEditor,
       !EditorRegistry.registry.contains(where: { $0.id == storedID }) {
      logger.info("Project \(project.id): stale defaultEditor '\(storedID)'; resetting to nil")
      project.defaultEditor = nil
    }
  }
}
```

*Verification:*
- Unit test: create a mock `settings.json` with legacy `customEditors` array and a stale `defaultEditorID` string; verify migration sets both to appropriate values.
- Integration test: load a real settings file, verify no errors.

*Files modified:*
- `apps/mac/codans/App/Features/Settings/SettingsStore.swift` — add migration method called at load.

---

**Task 5.2: Refresh describe() cache on Settings pane appear**

Ensure fresh app discovery when the Settings pane is opened.

*Outcome:* In the Settings feature reducer, clear the `EditorService` cache when the pane becomes visible.

Since `LiveEditorService` caches descriptors, add a method:

```swift
protocol EditorService {
  func clearDescribeCache() async  // new
  // ... existing methods
}
```

And in the Settings pane effect:

```swift
.onAppear {
  state.editorService.clearDescribeCache()
}
```

*Verification:*
- Compile without errors.
- Integration test: call `clearDescribeCache()`, verify next `describe()` call re-probes.

*Files modified:*
- `apps/mac/codans/App/Clients/Editor/EditorService.swift` — add cache-clear method.
- `apps/mac/codans/App/Clients/Editor/EditorService+Live.swift` — implement it.
- Settings pane feature reducer — call on pane appear.

---

### Phase 6: Testing (depends on Phase 5)

**Task 6.1: Registry sanity tests**

Verify the registry is well-formed.

*Outcome:* Test suite `EditorRegistryTests`:

```swift
func testRegistryCount() {
  XCTAssertEqual(EditorRegistry.registry.count, 28)
}

func testRegistryUniqueIDs() {
  let ids = EditorRegistry.registry.map { $0.id }
  XCTAssertEqual(ids.count, Set(ids).count, "Duplicate editor IDs")
}

func testRegistryBundleIDs() {
  for desc in EditorRegistry.registry {
    if desc.launchMode != .shellEditor {
      XCTAssertFalse(desc.bundleIdentifier.isEmpty, "Non-shellEditor must have bundleID: \(desc.id)")
    } else {
      XCTAssertTrue(desc.bundleIdentifier.isEmpty, ".shellEditor must have empty bundleID")
    }
  }
}

func testPriorityListsNoOmissions() {
  let editorIDs = EditorRegistry.registry.filter { ... }.map { $0.id }
  for id in editorIDs {
    XCTAssertTrue(EditorRegistry.editorPriority.contains(id), "Missing from editorPriority: \(id)")
  }
}

func testMenuOrderIncludesAllCategories() {
  XCTAssertTrue(EditorRegistry.menuOrder.contains("editor"), ".editor must be in menuOrder")
  XCTAssertTrue(EditorRegistry.menuOrder.contains("finder"), "Finder must be in menuOrder")
}
```

*Verification:*
- All tests pass.
- Run: `make mac-test Tests/EditorRegistryTests.swift`.

---

**Task 6.2: EditorService resolution tests**

Verify the cascade logic.

*Outcome:* Test suite `EditorServiceTests`:

```swift
func testResolvePreferredStrict() {
  // If preferred is set and installed, use it.
  launcher.stub(bundleID: "com.microsoft.VSCode", appURL: vscodeURL)
  let resolved = await service.resolve(preferred: "vscode")
  XCTAssertEqual(resolved.id, "vscode")
}

func testResolvePreferredNotInstalledThrows() {
  // If preferred is set and NOT installed, throw.
  launcher.stub(bundleID: "com.microsoft.VSCode", appURL: nil)
  XCTAssertThrowsAsync {
    try await service.resolve(preferred: "vscode")
  }
}

func testResolveGlobalDefaultLenient() {
  // If no preferred, use global default if installed.
  launcher.stub(bundleID: "dev.zed.Zed", appURL: zedURL)
  settingsStore.general.defaultEditorID = "zed"
  let resolved = await service.resolve(preferred: nil)
  XCTAssertEqual(resolved.id, "zed")
}

func testResolveGlobalDefaultFallthrough() {
  // If global default is stale/uninstalled, fall through to priority.
  launcher.stub(bundleID: "dev.zed.Zed", appURL: nil)  // zed not installed
  launcher.stub(bundleID: "com.microsoft.VSCode", appURL: vscodeURL)
  settingsStore.general.defaultEditorID = "zed"
  let resolved = await service.resolve(preferred: nil)
  // Should pick first installed from priority, which is vscode
  XCTAssertEqual(resolved.id, "vscode")
}

func testResolveFallbackToFinder() {
  // Always terminates at Finder.
  launcher.stubAll(appURL: nil)
  launcher.stub(bundleID: "com.apple.finder", appURL: finderURL)
  let resolved = await service.resolve(preferred: nil)
  XCTAssertEqual(resolved.id, "finder")
}
```

*Verification:*
- All tests pass.
- Run: `make mac-test Tests/EditorServiceTests.swift`.

---

**Task 6.3: Launch mode tests**

Verify the JetBrains + NSWorkspace branching.

*Outcome:* Test suite `EditorServiceLaunchTests`:

```swift
func testLaunchDirectoryMode() {
  let desc = EditorDescriptor(..., launchMode: .directory, appURL: vscodeURL)
  await service.open(directory: tempDir, preferred: "vscode")
  
  XCTAssertEqual(launcher.lastOpenCall?.urls, [tempDir])
  XCTAssertEqual(launcher.lastOpenCall?.appURL, vscodeURL)
  XCTAssertEqual(launcher.lastOpenCall?.configuration.createsNewApplicationInstance, false)
}

func testLaunchApplicationWithArgumentsMode() {
  let desc = EditorDescriptor(..., launchMode: .applicationWithArguments, appURL: intellijURL)
  await service.open(directory: tempDir, preferred: "intellij")
  
  XCTAssertEqual(launcher.lastOpenCall?.configuration.arguments, [tempDir.path])
  XCTAssertEqual(launcher.lastOpenCall?.configuration.createsNewApplicationInstance, true)
}
```

*Verification:*
- All tests pass.
- Specifically test all JetBrains entries (intellij, webstorm, pycharm, rubymine, rustrover) use `.applicationWithArguments`.

---

**Task 6.4: Migration tests**

Verify stale defaults are normalized.

*Outcome:* Test suite `EditorMigrationTests`:

```swift
func testMigrateStalePrimaryDefault() {
  let json = #"{"general":{"defaultEditorID":"customEmacs"}}"#
  let settings = try JSONDecoder().decode(GeneralSettings.self, from: json.data(using: .utf8)!)
  XCTAssertEqual(settings.defaultEditorID, nil, "Stale ID should be reset")
}

func testMigrateIgnoresCustomEditors() {
  let json = #"{"customEditors":[{"id":"vim","command":"nvim"}]}"#
  // Should decode without error, and customEditors array is ignored in runtime.
  let settings = try JSONDecoder().decode(SettingsStore.self, from: json.data(using: .utf8)!)
  // No assertion; goal is "doesn't crash".
}
```

*Verification:*
- All tests pass.
- Run: `make mac-test Tests/EditorMigrationTests.swift`.

---

**Task 6.5: Integration smoke test (optional, gated)**

Actually open a temp directory in Finder via NSWorkspace.

*Outcome:* Test gated by env var `TC_RUN_EDITOR_INTEGRATION_TESTS=1`:

```swift
#if TC_RUN_EDITOR_INTEGRATION_TESTS
func testRealFinderOpen() {
  let tempDir = FileManager.default.temporaryDirectory
  XCTAssertNoThrowAsync {
    try await service.open(directory: tempDir, preferred: nil)
  }
}
#endif
```

Run only locally or in nightly CI.

*Verification:*
- Run: `TC_RUN_EDITOR_INTEGRATION_TESTS=1 make mac-test`.

---

### Phase 7: Cleanup & Review

**Task 7.1: Remove stale references**

Grep for references to removed C8 types and ensure they're cleaned up.

*Outcome:* Verify no code in the app or CLI references:
- `ProcessSpawner`
- `PathProber`
- `EditorEnv`
- `CustomEditor`
- `CommandTemplate`

Run:
```bash
grep -r "ProcessSpawner" apps/mac/codans --include="*.swift"
grep -r "PathProber" apps/mac/codans --include="*.swift"
# etc.
```

Expected: zero results.

*Verification:*
- All greps return zero results.
- Build succeeds.

---

**Task 7.2: Build, lint, and test**

Full end-to-end build.

*Outcome:* Run:
```bash
make mac-build        # Full build
make mac-lint         # SwiftLint, SwiftFormat
make mac-test         # All unit tests
```

All three pass.

*Verification:*
- Build succeeds with no warnings.
- Linter passes.
- Test suite passes (100+ tests, including registry, service resolution, migration, UI snapshots).

---

## Work Organization & Parallelization

**Sequential Phases:**
1. **Phase 1** (Verification) — must complete before Phase 2 to unblock `.editor` decision.
2. **Phase 2–4** (Core + UX) — can run in parallel after Phase 1.
   - Task 2.1–2.4 can run in parallel (no dependencies).
   - Task 3.1–3.3 depend on Task 2.1–2.4 completing.
   - Task 4.1–4.4 depend on Task 3.1–3.3 completing.
5. **Phase 5–6** (Integration + Tests) — depend on Phase 4 completing.
6. **Phase 7** (Cleanup) — final gate before review.

**Agent Team Dispatch (if approved for parallel work):**

Given the Feedback memory about agent team preference, recommend the following parallel groups after Phase 1:

- **Team A:** Registry + Models + AppLauncher (Tasks 2.1–2.4)
- **Team B:** EditorService refactor (Tasks 3.1–3.3)
- **Team C:** Settings UX (Tasks 4.1–4.4)

Once Teams A–C complete and merge incrementally:
- **Team D:** Migration + Testing (Tasks 5.1–6.5)
- **Team E:** Cleanup (Task 7.1–7.2)

---

## Risks and Mitigations

**Risk R1: ToDesktop bundle ID changes**
- *Mitigation:* Add `alternateBundleIdentifiers: [String]` field to descriptor; update list if Cursor re-publishes.
- *Task:* Addressed in Task 2.1 (registry design includes this field).

**Risk R2: Pane `.editor` primitive doesn't exist**
- *Mitigation:* Task 1.1 verifies availability. If missing, drop `.editor` from registry (one-line change) and defer.
- *Task:* Addressed in Phase 1. If blocked, mark as a blocker and proceed without `.editor`.

**Risk R3: JetBrains launch mode breaks**
- *Mitigation:* Manual smoke test on one JetBrains IDE in each release.
- *Task:* Addressed in Task 6.3 (automated test coverage).

**Risk R4: First-install race (Cursor installed while codans is running)**
- *Mitigation:* `describe()` re-probes on Settings-appear and IPC call; cache is not persistent.
- *Task:* Addressed in Task 5.2 (cache refresh on Settings pane appear).

**Risk R5: Loss of niche custom editors**
- *Mitigation:* `customEditors` array is silently ignored; if a user requests an editor (e.g. Helix), add it to registry (2-line code change).
- *Task:* Addressed in Task 5.1 (migration handles this gracefully).

**Risk R6: NSWorkspace.open callback error swallowing**
- *Mitigation:* Wrap in `withCheckedThrowingContinuation` and unit test both paths.
- *Task:* Addressed in Task 3.1 (implementation detail) and Task 6.3 (test coverage).

---

## Verification & Sign-Off

Before marking C8a implementation complete:

- [ ] All Phase 1 tasks complete (verification + groundwork).
- [ ] All Phase 2–4 tasks complete and merged incrementally.
- [ ] All Phase 5–6 tests pass (100+ test cases).
- [ ] Phase 7 cleanup: zero stale references, clean build.
- [ ] Settings pane shows only installed editors; Project Options picker works end-to-end.
- [ ] IPC methods `editor.describe`, `editor.open`, `editor.setGlobalDefault`, `editor.setProjectDefault` all respond correctly.
- [ ] Migration: legacy settings load without error; stale IDs reset to nil.
- [ ] CLI `codans open [path] [--in <editor>]` works correctly.
- [ ] Manual smoke test: open a directory in VSCode, Finder, and one terminal app.

---

## Next Steps

Present this plan for approval. On approval:
1. Invoke `/hs-exec-plan` to create task list in `docs/exec-plans/c8a-tasks.json`.
2. Dispatch Phase 1 tasks (verification + groundwork) to an agent or self.
3. After Phase 1, dispatch parallel agent teams to Phases 2–4.
4. As each team completes a task, invoke `/commit` incrementally (one commit per task or logical group).
5. After all tasks complete, verify against the checklist above and mark done.

---

## Progress

### 2026-04-22 — Phase 1 complete

**Task 1.1 — Pane `.editor` primitive check:** **Partial.** Building blocks exist:
- `PaneSurface.sendInput(_ text: String)` — `apps/mac/codans/Runtime/Ghostty/PaneSurface.swift:118`, fully exposed, production-ready.
- `HierarchyManager.openPanel(workingDirectory:initialCommand:)` — accepts both parameters; stores `initialCommand` on the Pane; flows through IPC.

**Missing:** `TerminalEngine.ensureSurface()` does not forward `pane.initialCommand` to the newly created `PaneSurface`. **3-line fix** required — added as Task 4d in the task list.

**Decision:** Ship `.editor` in C8a v1 with the TerminalEngine wiring patch. Zero architectural risk, ~5 minutes of work.

**Task 1.2 — SettingsStore + Project audit:**

- `GeneralSettings` at `apps/mac/CodansCore/Settings/GeneralSettings.swift`: has `defaultEditorID: EditorID?` (where `EditorID = String`) and `customEditors: [CustomEditor]`.
- Settings loader: `SettingsMigration.load(from:)` at `apps/mac/CodansCore/Settings/SettingsMigration.swift` — handles v1→v2 atomic migration with `.broken-<timestamp>` backup on failure.
- Logger: `Logger(subsystem: "com.gumpw.codans.persistence", category: "settings")`.
- `customEditors` references only in SettingsStore (UI-local: `addCustomEditor`/`updateCustomEditor`/`removeCustomEditor`). **No runtime callers outside settings UI** — migration is safe.
- `Project.defaultEditor` at `apps/mac/CodansCore/Project.swift:21` is already `String?`; no type change needed. Written via `HierarchyManager.setDefaultEditor` / `setDefaultEditorAnySpace` — both persist via `store.scheduleSave(catalog)`.

**Decision:** Add `garbageCollectEditors()` method on `Settings` (mutating) invoked in `SettingsStore.__init__` after the `SettingsMigration.load()` call. Similarly normalize `Project.defaultEditor` during catalog load.

**Task 1.3 — HierarchyClient API review:**

- **`project(containing:)` does NOT exist.** Use `isPathRegistered(canonical: String) -> (SpaceID, ProjectID)?` — synchronous, `@MainActor`, location `apps/mac/codans/Runtime/HierarchyManager.swift:219`.
- **Must canonicalize the path first** via `HierarchyManager.canonicalPath(_:)` (resolves symlinks; critical for `/tmp` vs `/private/var/...` on macOS).
- Once `(spaceID, projectID)` known, read `Project.defaultEditor` by walking `hierarchyClient.snapshot().spaces[...].projects[...]`.
- **Write:** `setRepositoryDefaultEditor(_ projectID: ProjectID, _ editorID: EditorID?) throws` — works across all Spaces (no SpaceID arg needed); throws `HierarchyError.notFound` on unknown projectID.
- `EditorID = String` (typealias in `CodansCore/Editor/EditorStorageModels.swift`).
- TCA wiring: `@Dependency(\.hierarchyClient)` already registered via `DependencyKey`.

**Decision:** IPC handler (`EditorHandlers.swift`) imports `HierarchyClient`; for `editor.open` without `preferred`, it calls `isPathRegistered(canonical: HierarchyManager.canonicalPath(path))` and reads `.defaultEditor` from the catalog snapshot. Service signature unchanged.

### 2026-04-22 — Implementation complete (Phase 2–7)

Six commits landed on `refactor/open-editor`, one per phase:

| Phase | Commit | Summary |
|---|---|---|
| 2 — Core infrastructure | `0d132c8` | 28-entry `EditorRegistry`, `EditorModels` + `LaunchMode`, `AppLauncher` protocol + `LiveAppLauncher`, 3-case `EditorError`. |
| 3 — Service refactor | `a2d5bf9` | `LiveEditorService` cascade + cache, `TestEditorService` + `RecordingAppLauncher`, retired `ProcessSpawner` / `PathProber` / `EditorEnv` / `SpawnContract` / `CustomEditor`. |
| 4a/4b — UX layers | `4a3bdff` | Settings default-editor pane + Project Options per-repo override, both bound to installed-only descriptor list. |
| 4c/4d — IPC + Pane wiring | `07945c4` | `editor.{describe,open,setGlobalDefault,setProjectDefault}` handlers with per-Project override lookup; `TerminalEngine.ensureSurface` forwards `pane.initialCommand` so `$EDITOR` can reach the shell. |
| 5 — Migration + cache refresh | `2d75abd` | `Settings.garbageCollectEditors` + `Catalog.garbageCollectEditors` run once at load; `EditorService.clearCache()` invoked on Settings-pane appear and on every `editor.describe` IPC call. |
| 6 — Tests | `6bd2875` | Registry sanity (10 tests), service resolution (8 tests), launch branching (8 tests), migration (10 tests), IPC handlers (7 tests), EditorFeature (5 tests) — 51 total, all green. |
| 7 — Cleanup + progress log | *this commit* | Pruned stale comment references (`EditorEnv`, `LiveProcessSpawnerIntegrationTests`); appended this entry. |

**Known limitation — `.shellEditor` deferred.** The `.shellEditor` registry row is probed and appears in `describe()` results, but `EditorService.open` currently throws a descriptive `.launchFailed` because the service signature (`open(directory: URL, preferred: EditorID?)`) intentionally excludes domain types (Pane / Tab context). The Pane primitive itself was completed in Phase 4d — callers that want `$EDITOR` end-to-end should route through `hierarchy.openPane` with `initialCommand: "$EDITOR"`. A future iteration either widens the service signature or adds a separate `EditorService.openShell(panelContext:)` entry point. Tracked inline in `EditorService+Live.swift` (search `"Pane" + "Tab context"`).

### 2026-04-22 — Codex review follow-up (P1+P2)

Seven post-merge fixes applied after Codex review, landed in two commits:

- **P1-1** (`describe()` filters `.shellEditor`): the registry entry stays but is suppressed from `describe()` so it can no longer be saved as a default that always fails to launch. Filtering is reversible — remove the `continue` when a Pane-aware open path lands. Tests: `EditorServiceResolutionTests.describeReturnsInstalledOnlyAndExcludesShellEditor`, `EditorServiceLaunchTests.shellEditorIsUnreachableFromOpenInV1`.
- **P1-2** (JetBrains launch API): `AppLauncher` gained `openApplication(at:configuration:)`; `.applicationWithArguments` routes through it so `configuration.arguments` actually reach the IDE. Tests: `EditorServiceLaunchTests.applicationWithArgumentsLaunchRoutesThroughOpenApplicationWithDirPathArgument`, `allJetBrainsIDsUseOpenApplicationBranch`.
- **P2-3** (priority cascade respected): reducers hand `nil` (not `"finder"`) to the service when neither override nor global default applies, so the service's priority walk picks the first installed editor. New helper: `EditorFeature.resolveInstalledPreference`.
- **P2-4** (subdirectory project lookup): `HierarchyManager.project(containing:)` + `HierarchyClient.projectContaining` — `codans open` inside a Project subdirectory now honors the Project's default editor. Deepest-match disambiguation when Projects nest.
- **P2-5** (Git Viewer honors project override): `GitViewerFeature.editorOpenRequest` looks up `projectID.defaultEditor` and filters through installed descriptors before handing `preferred` to the service.
- **P2-6** ("Automatic" row in Settings): `SettingsGeneralView` gained a sentinel `EditorID?(nil)` row so users can clear the global default after picking something.
- **P2-7** (Finder priority bug, design doc bug): `defaultPriority` moved Finder to the tail — previously Finder sat mid-list, shadowing every terminal and git client in auto-resolution since Finder is always installed. Design doc `c8a-editor-integration-nsworkspace.md` also corrected.

---

## Decision Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-04-22 | Ship `.editor` in C8a v1; add 3-line TerminalEngine.ensureSurface() fix as Task 4d. | Building blocks exist (`sendInput`, `initialCommand` plumbing); gap is a trivial wiring patch, not a design change. Phase 1 verification confirmed low risk. |
| 2026-04-22 | IPC handler uses `isPathRegistered` + `canonicalPath` for project reverse-lookup instead of designing a `project(containing:)` method. | Existing API is sufficient; adding a new `HierarchyClient` method for a single call site is unnecessary abstraction. |
| 2026-04-22 | `Project.defaultEditor` type stays `String?` (not an `EditorID` enum/typealias migration). | `EditorID` is already just `String` via typealias; no structural change. Value-level migration (drop unknown IDs) is sufficient. |
| 2026-04-22 | Migration hook `garbageCollectEditors()` runs once post-load in `SettingsStore.__init__`, not in `SettingsMigration.migrate`. | Separation of concerns: `SettingsMigration` handles schema version, `garbageCollectEditors` handles value-domain normalization. Avoids coupling registry changes to schema version bumps. |
| 2026-04-22 | Phase 2 runs as single agent (not parallel fan-out). | Types in EditorRegistry / EditorModels / AppLauncher / EditorError are tightly coupled; one agent keeps them consistent and avoids merge conflicts. Phase 4 fans out into 4 parallel teams once Phase 3 merges. |

---

## Surprises & Discoveries

- **`EditorID` is `String`, not an enum.** C8a design doc implicitly treated it as a sum type; reality is a raw string. This simplifies migration (no case-by-case mapping) but also means there's no compiler guarantee that a stored ID is in the registry — hence the explicit `garbageCollectEditors()` pass.

- **`HierarchyManager.canonicalPath(_:)` is mandatory, not optional.** macOS symlink quirks (`/tmp` → `/private/var/folders/...`) will silently break `isPathRegistered` lookup if callers hand in unnormalized paths. Plan updates reflect this.

- **`customEditors` has no known runtime callers outside settings UI.** Risk R5 (loss of niche custom editors) is effectively zero blast radius — current users could only have noticed if they edited settings.json directly. Migration can silently drop without user-facing disclosure.
