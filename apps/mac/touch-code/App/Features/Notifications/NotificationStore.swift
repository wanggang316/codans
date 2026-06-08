import Foundation
import Observation
import TouchCodeCore
import os.log

/// `@MainActor @Observable` owner of `~/.config/touch-code/notifications.json`.
/// Single writer for the file; mirrors the `SettingsStore` and `CatalogStore`
/// pattern: atomic-rename writes via `AtomicFileStore`, trailing debounce on
/// mutations, age + cap sweeps applied on every load and after every append.
///
/// All non-trivial inbox-mutation policy lives in `TouchCodeCore.InboxStorage`
/// (pure, nonisolated, fully unit-tested). This class is a thin wrapper that
/// adds persistence + observation semantics.
@MainActor
@Observable
public final class NotificationStore {
  /// Newest-first list of inbox entries. Views observe this property.
  public private(set) var entries: [InboxEntry]

  /// Cached count of unread entries. Recomputed on every mutation; cheaper
  /// for views to read than scanning `entries`.
  public private(set) var unreadCount: Int

  /// Non-nil when the inbox file on disk announced a `version` greater
  /// than this build understands and was renamed aside at launch. Set in
  /// `init` from `InboxFile.LoadResult`; never mutated thereafter. The
  /// UI (M8.T1 "Inbox reset" toast) reads this once and surfaces the
  /// backup basename to the user.
  public private(set) var loadedQuarantineBackupURL: URL?

  @ObservationIgnored private let fileURL: URL
  @ObservationIgnored private let logger = Logger(
    subsystem: "com.touch-code.persistence",
    category: "notifications"
  )
  @ObservationIgnored private let debounceWindow: Duration
  @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?

  /// Trailing debounce between a mutation and the atomic-rename write. Lower
  /// than `SettingsStore` (500 ms) because notifications can fire in bursts
  /// and the user wants the inbox file to reflect reality quickly after a
  /// long-running command finishes.
  public static let debounceWindow: Duration = .milliseconds(250)

  /// On-disk location: `<AppDirectories.configDirectory>/notifications.json`
  /// (`-dev` suffixed for Debug builds — see `AppDirectories`).
  public static func defaultURL(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    AppDirectories.configDirectory(home: home)
      .appendingPathComponent("notifications.json", isDirectory: false)
  }

  public init(
    fileURL: URL = NotificationStore.defaultURL(),
    debounceWindow: Duration = NotificationStore.debounceWindow,
    now: Date = Date()
  ) {
    self.fileURL = fileURL
    self.debounceWindow = debounceWindow

    var loaded: [InboxEntry]
    var quarantineBackupURL: URL?
    do {
      if let result = try InboxFile.load(from: fileURL, now: now) {
        loaded = result.entries
        quarantineBackupURL = result.quarantineBackupURL
      } else {
        loaded = []
      }
    } catch {
      logger.error(
        "Failed to load notifications.json: \(String(describing: error), privacy: .public); starting empty inbox"
      )
      loaded = []
    }
    self.loadedQuarantineBackupURL = quarantineBackupURL

    // Apply both sweeps before exposing the inbox so the user never sees a
    // stale row on first paint.
    loaded = InboxStorage.aged(loaded, asOf: now)
    loaded = InboxStorage.capped(loaded)

    self.entries = loaded
    self.unreadCount = InboxStorage.unreadCount(loaded)
  }

  // MARK: - Mutators

  /// Append a new entry. Applies the 30 s `(paneID, kind)` dedup window —
  /// duplicates merge in place rather than creating a new row. Never grows
  /// the inbox past `InboxStorage.cap`.
  public func append(_ entry: InboxEntry) {
    entries = InboxStorage.appending(entry, to: entries)
    unreadCount = InboxStorage.unreadCount(entries)
    scheduleSave()
  }

  /// Mark a single entry read. No-op if the entry is missing or already read.
  public func markRead(id: NotificationID) {
    let updated = InboxStorage.markingRead(id: id, in: entries)
    guard updated != entries else { return }
    entries = updated
    unreadCount = InboxStorage.unreadCount(entries)
    scheduleSave()
  }

  /// Mark every unread entry read with a single timestamp.
  public func markAllRead() {
    let updated = InboxStorage.markingAllRead(in: entries)
    guard updated != entries else { return }
    entries = updated
    unreadCount = 0
    scheduleSave()
  }

  /// R1: when the user focuses a pane, every unread entry whose source
  /// pane matches is marked read in one pass. Idempotent — a no-op when
  /// the pane has no unread entries.
  public func markReadForPane(_ paneID: PaneID, at readAt: Date = Date()) {
    var didMutate = false
    let updated = entries.map { entry -> InboxEntry in
      guard entry.source.paneID == paneID, entry.isUnread else { return entry }
      didMutate = true
      var copy = entry
      copy.readAt = readAt
      return copy
    }
    guard didMutate else { return }
    entries = updated
    unreadCount = InboxStorage.unreadCount(entries)
    scheduleSave()
  }

  /// Clear roll-up indicators for unread entries whose source pane is no
  /// longer present in the live catalog. Called once at startup and on
  /// every catalog mutation that could remove a pane (close pane / tab,
  /// remove worktree / project). Idempotent — a no-op when every unread
  /// entry still points at a live pane.
  public func sweepOrphanUnreads(livePaneIDs: Set<PaneID>, at readAt: Date = Date()) {
    let updated = InboxStorage.markingReadForOrphanPanes(
      livePaneIDs: livePaneIDs,
      in: entries,
      at: readAt
    )
    guard updated != entries else { return }
    entries = updated
    unreadCount = InboxStorage.unreadCount(entries)
    scheduleSave()
  }

  // MARK: - Persistence

  /// Cancels any pending debounced write and flushes immediately. Callers:
  /// `applicationWillTerminate`, test teardown, manual recovery paths.
  public func flush() {
    do {
      pendingSaveTask?.cancel()
      pendingSaveTask = nil
      try InboxFile.save(entries, to: fileURL)
    } catch {
      logger.error("Failed to flush notifications: \(String(describing: error), privacy: .public)")
    }
  }

  private func scheduleSave() {
    // Capture the in-memory snapshot up front so a debounced write
    // serialises the value at the moment of mutation; subsequent
    // mutations cancel-and-replace this Task. flush() bypasses the
    // queue entirely and writes the *current* `entries` rather than
    // any captured snapshot — that's the right call on app
    // termination, where the latest state must reach disk.
    pendingSaveTask?.cancel()
    let snapshot = entries
    pendingSaveTask = Task { [weak self] in
      let window = self?.debounceWindow ?? Self.debounceWindow
      try? await Task.sleep(for: window)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      do {
        try InboxFile.save(snapshot, to: self.fileURL)
      } catch {
        // Log and leave the existing file untouched. Same trade-off as
        // SettingsStore: a transient disk-full / permissions flip should
        // not cost the user their persisted inbox; the next successful
        // save picks up the in-memory snapshot.
        self.logger.error(
          "Failed to save notifications: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }
}
