import CodansCore
import CodansIPC
import Foundation

/// Renames, `git worktree prune`, and the split-tree verbs (`splitPane`,
/// `resizePane`) — the sidebar and context-menu actions the CLI had no
/// spelling for. Each goes through the same manager call the UI uses.
extension HierarchyHandlers {
  // MARK: - Renames

  public struct RenameProjectParams: Codable, Sendable {
    public let id: ProjectID
    public let name: String
  }
  /// `hierarchy.renameProject` — sets the sidebar label. A blank name (or
  /// the folder name itself) clears the override, like the sidebar's
  /// rename field.
  public func renameProject(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let req = try? params.decoded(as: RenameProjectParams.self) else {
      return .failed(.invalidParams(message: "renameProject requires {id, name}", path: nil))
    }
    do {
      try manager.renameProject(req.id, name: req.name)
      let name = manager.catalog.projects.first(where: { $0.id == req.id })?.name ?? req.name
      return .unary(try JSONValue.encoded(RenameResult(id: req.id.description, name: name)))
    } catch {
      return failure(for: error, fallbackKind: "project", fallbackID: req.id.description)
    }
  }

  public struct RenameWorktreeParams: Codable, Sendable {
    public let id: WorktreeID
    public let projectID: ProjectID
    public let name: String
  }
  /// `hierarchy.renameWorktree` — the display label only; path and branch
  /// are untouched. Blank names are refused: a worktree row always shows
  /// something, and there is no "auto" fallback to clear to.
  public func renameWorktree(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let req = try? params.decoded(as: RenameWorktreeParams.self) else {
      return .failed(
        .invalidParams(message: "renameWorktree requires {id, projectID, name}", path: nil))
    }
    let name = req.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      return .failed(.invalidParams(message: "worktree name must not be blank", path: ["name"]))
    }
    do {
      try manager.renameWorktree(req.id, in: req.projectID, name: name)
      return .unary(try JSONValue.encoded(RenameResult(id: req.id.description, name: name)))
    } catch {
      return failure(for: error, fallbackKind: "worktree", fallbackID: req.id.description)
    }
  }

  public struct RenameTabParams: Codable, Sendable {
    public let id: TabID
    public let name: String?
  }
  /// `hierarchy.renameTab` — a blank or missing name clears the user's
  /// title so the tab follows the shell's live title again.
  public func renameTab(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let req = try? params.decoded(as: RenameTabParams.self) else {
      return .failed(
        .invalidParams(message: "renameTab requires {id}", path: nil))
    }
    let trimmed = req.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name: String? = trimmed.isEmpty ? nil : trimmed
    do {
      try manager.renameTab(req.id, name: name)
      return .unary(try JSONValue.encoded(RenameResult(id: req.id.description, name: name)))
    } catch {
      return failure(for: error, fallbackKind: "tab", fallbackID: req.id.description)
    }
  }

  public struct RenameResult: Codable, Sendable {
    public let id: String
    public let name: String?
  }

  // MARK: - Prune

  public struct PruneWorktreesParams: Codable, Sendable {
    public let projectID: ProjectID
  }
  public struct PruneWorktreesResult: Codable, Sendable {
    public let pruned: Int
  }
  /// `hierarchy.pruneWorktrees` — `git worktree prune` on the project's
  /// repository, then the same reconcile the sidebar runs so rows whose
  /// directories are gone leave the catalog.
  public func pruneWorktrees(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let req = try? params.decoded(as: PruneWorktreesParams.self) else {
      return .failed(.invalidParams(message: "pruneWorktrees requires {projectID}", path: nil))
    }
    guard let project = manager.catalog.projects.first(where: { $0.id == req.projectID }) else {
      return .failed(.notFound(kind: "project", id: req.projectID.description))
    }
    guard !project.isRemote else {
      return .failed(.unsupported(reason: "prune runs git locally; \(project.name) is a remote project"))
    }
    guard let gitRoot = project.gitRoot else {
      return .failed(
        .invalidParams(message: "\(project.name) is not a git project", path: ["projectID"]))
    }
    guard let worktreePruner else {
      return .failed(.unsupported(reason: "worktree prune is not available in this build"))
    }
    do {
      let pruned = try await worktreePruner(URL(fileURLWithPath: gitRoot, isDirectory: true))
      await reconcileWorktrees(project.id)
      return .unary(try JSONValue.encoded(PruneWorktreesResult(pruned: pruned)))
    } catch let error as GitWorktreeError {
      return .failed(Self.ipcError(for: error))
    } catch {
      return .failed(.internal("git worktree prune failed: \(error)"))
    }
  }

  // MARK: - Split tree

  public struct SplitPaneParams: Codable, Sendable {
    /// The anchor: a Pane id, or a Tab / Content id (its Pane).
    public let paneID: UUID
    public let direction: SplitTree<PaneID>.NewDirection
    /// Defaults to the anchor's selected Tab's live directory, so the new
    /// shell starts where its neighbour is.
    public let workingDirectory: String?
    public let initialCommand: String?
    public let labels: [String]?
  }
  /// The Pane a split produced and the Tab it opened with.
  public struct SplitResult: Codable, Sendable {
    public let paneID: PaneID
    public let tabID: TabID
    public let contentID: ContentID
  }
  /// `hierarchy.splitPane` — a new Pane with a fresh Tab beside the
  /// anchor, the way the keyboard split does, with the project env every
  /// CLI-spawned session gets.
  public func splitPane(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let req = try? params.decoded(as: SplitPaneParams.self) else {
      return .failed(.invalidParams(message: "splitPane requires {paneID, direction}", path: nil))
    }
    guard let anchorID = layoutPane(for: req.paneID),
      let address = manager.catalog.address(forPane: anchorID),
      let anchor = manager.catalog.pane(anchorID),
      let anchorTab = anchor.selectedTab
    else {
      return .failed(.notFound(kind: "pane", id: req.paneID.uuidString))
    }
    let requested =
      req.workingDirectory
      ?? overlayLiveDirectories(in: [anchorTab])[0].content.terminal?.workingDirectory
      ?? NSHomeDirectory()
    let workingDirectory = effectiveWorkingDirectory(
      requested, projectID: address.projectID, worktreeID: address.worktreeID)
    do {
      let created = try manager.splitPane(
        from: anchorID,
        direction: req.direction,
        content: .terminal(
          workingDirectory: workingDirectory, initialCommand: req.initialCommand,
          labels: Set(req.labels ?? []))
      )
      try await manager.ensureSurface(for: created.contentID, env: envProvider(address.projectID))
      manager.focusSurfaceView(for: created.contentID)
      return .unary(
        try JSONValue.encoded(
          SplitResult(paneID: created.paneID, tabID: created.tabID, contentID: created.contentID)))
    } catch {
      return failure(for: error, fallbackKind: "pane", fallbackID: req.paneID.uuidString)
    }
  }

  public struct ResizePaneParams: Codable, Sendable {
    /// A Pane id, or a Tab / Content id (its Pane).
    public let paneID: UUID
    /// Which edge grows: `left` / `right` move the nearest vertical divider,
    /// `up` / `down` the nearest horizontal one.
    public let direction: SplitTree<PaneID>.NewDirection
    /// Pixels, as ghostty's resize keybind sends them; the manager scales
    /// them onto the split ratio. Default is a visible nudge.
    public let amount: Double?
  }
  /// `hierarchy.resizePane` — nudge the divider next to `paneID`. A Pane
  /// with no split in that orientation is a no-op, like the keybind.
  public func resizePane(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let req = try? params.decoded(as: ResizePaneParams.self) else {
      return .failed(.invalidParams(message: "resizePane requires {paneID, direction}", path: nil))
    }
    let amount = req.amount ?? 40
    guard amount > 0 else {
      return .failed(.invalidParams(message: "amount must be positive", path: ["amount"]))
    }
    guard let paneID = layoutPane(for: req.paneID) else {
      return .failed(.notFound(kind: "pane", id: req.paneID.uuidString))
    }
    let direction: ResizeDirection
    switch req.direction {
    case .left: direction = .left
    case .right: direction = .right
    case .up: direction = .up
    case .down: direction = .down
    }
    do {
      try manager.resizePane(paneID, direction: direction, amount: amount)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "pane", fallbackID: req.paneID.uuidString)
    }
  }

  public struct EqualizePanesParams: Codable, Sendable {
    public let projectID: ProjectID
    public let worktreeID: WorktreeID
  }
  /// `hierarchy.equalizePanes` — every divider of the Worktree's split
  /// tree back to an even split.
  public func equalizePanes(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let req = try? params.decoded(as: EqualizePanesParams.self) else {
      return .failed(.invalidParams(message: "equalizePanes requires {projectID, worktreeID}", path: nil))
    }
    do {
      try manager.equalizeSplits(in: req.worktreeID, in: req.projectID)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "worktree", fallbackID: req.worktreeID.description)
    }
  }

  public struct ZoomPaneParams: Codable, Sendable {
    /// A Pane id, or a Tab / Content id (its Pane).
    public let id: UUID
  }
  public struct ZoomResult: Codable, Sendable {
    public let paneID: PaneID
    public let zoomed: Bool
  }
  /// `hierarchy.zoomPane` — toggles the zoom on the Pane (zoomed: it fills
  /// the layout area; again: back to the layout) and focuses it.
  public func zoomPane(_ params: JSONValue) async -> RouterOutcome {
    await setZoom(params, method: "zoomPane") { _ in true }
  }

  /// `hierarchy.unzoomPane` — leaves the zoom when the Pane is the zoomed
  /// one; otherwise a no-op.
  public func unzoomPane(_ params: JSONValue) async -> RouterOutcome {
    await setZoom(params, method: "unzoomPane") { isZoomed in isZoomed }
  }

  private func setZoom(
    _ params: JSONValue, method: String, shouldToggle: (_ isZoomed: Bool) -> Bool
  ) async -> RouterOutcome {
    await Task.yield()
    guard let req = try? params.decoded(as: ZoomPaneParams.self) else {
      return .failed(.invalidParams(message: "\(method) requires {id}", path: nil))
    }
    guard let paneID = layoutPane(for: req.id), let address = manager.catalog.address(forPane: paneID),
      let worktree = worktree(address.worktreeID, in: address.projectID)
    else {
      return .failed(.notFound(kind: "pane", id: req.id.uuidString))
    }
    let isZoomed = worktree.splitTree.zoomed == paneID
    do {
      let zoomed = shouldToggle(isZoomed) ? try manager.toggleZoom(paneID) : isZoomed
      if let contentID = manager.catalog.pane(paneID)?.selectedTab?.contentID {
        manager.focusSurfaceView(for: contentID)
      }
      return .unary(try JSONValue.encoded(ZoomResult(paneID: paneID, zoomed: zoomed)))
    } catch {
      return failure(for: error, fallbackKind: "pane", fallbackID: req.id.uuidString)
    }
  }
}
