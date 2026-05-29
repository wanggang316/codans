import Darwin
import Foundation
import os.log

/// Persistent store for the per-pane `SessionCatalog`. Mirrors the
/// debounced atomic-rename loop used by the in-app catalog store: a
/// 500 ms timer coalesces bursts of mutations, and `flushPending()` is
/// available for synchronous flush at app termination.
///
/// `@MainActor` — the catalog is read on launch and written from the
/// pane-lifecycle paths that already run on the main actor. Off-main
/// callers would race with the debounce bookkeeping.
@MainActor
public final class SessionStore {
  private let fileURL: URL
  private let logger = Logger(subsystem: "com.touch-code.runtime", category: "runtime.session")

  private var pendingSaveTask: Task<Void, Never>?
  private var latestCatalog: SessionCatalog?

  /// Owning file descriptor for the LOCK_EX|LOCK_NB advisory lock on
  /// `sessions.json`. Held for the lifetime of the store and released
  /// from `release()` / `deinit`. `-1` means no lock is held (either
  /// because acquisition failed and the store was never returned, or
  /// because `release()` already ran). `nonisolated(unsafe)` so the
  /// `nonisolated deinit` can close the descriptor without hopping
  /// back onto the main actor — the fd is a POSIX primitive whose
  /// only mutation point is `init` / `release()` / `deinit`, and
  /// those are already serialised by the @MainActor caller.
  private nonisolated(unsafe) var lockFD: Int32 = -1

  /// Acquires an exclusive advisory lock on `fileURL` so a second
  /// touch-code instance cannot race the catalog. The file is created
  /// if missing (the directory is expected to already exist — callers
  /// use `Session.defaultURL()` whose parent is created elsewhere on
  /// the bring-up path). A successful `flock(LOCK_EX|LOCK_NB)` keeps
  /// the descriptor open for the lifetime of the store; if `flock`
  /// fails with `EWOULDBLOCK`/`EAGAIN`, `SessionStoreError.alreadyHeld`
  /// is thrown and the descriptor is closed — the caller is expected
  /// to degrade to "no-resume mode".
  ///
  /// Caveat: `AtomicFileStore.write` (used by `saveNow`) replaces the
  /// catalog via `rename(2)`, which means our fd ends up holding a
  /// lock on the *orphaned* inode after the first save. This is fine
  /// for the second-instance defense at launch (the race is decided
  /// during `init`, before any save), but two instances launching
  /// strictly after a save would each see a fresh inode and acquire
  /// independent locks. The right long-term fix is a sidecar
  /// `sessions.json.lock` whose inode never changes; tracked for a
  /// follow-up so the M5.T5 scope stays focused on the launch-race
  /// guard the brief calls out.
  public init(fileURL: URL) throws {
    self.fileURL = fileURL

    // O_RDWR|O_CREAT so we can take the lock even before the catalog
    // exists. 0o644 mirrors the mode AtomicFileStore writes (it can't
    // see the existing perms on first save, and there's no security-
    // sensitive content in sessions.json).
    let fd = fileURL.path.withCString { path in
      Darwin.open(path, O_RDWR | O_CREAT, 0o644)
    }
    if fd < 0 {
      let err = errno
      throw SessionStoreError.write(
        "open(\(fileURL.path)) failed: errno=\(err)"
      )
    }
    // `fcntl(F_SETLK)` with a whole-file `struct flock` gives us the
    // same "exclusive, non-blocking, inode-scoped" semantics as
    // `flock(LOCK_EX|LOCK_NB)`. We use fcntl because Swift's Darwin
    // overlay imports both the `flock` C function and the
    // `struct flock` type into the same namespace, and the type wins
    // name resolution — calling the function directly is awkward.
    // fcntl-based locking is also POSIX (`flock(2)` is BSD-only) so
    // this keeps the code portable to a hypothetical Linux build.
    var lock = Darwin.flock(
      l_start: 0,
      l_len: 0,  // 0 = "to EOF" per F_SETLK semantics
      l_pid: 0,
      l_type: Int16(F_WRLCK),
      l_whence: Int16(SEEK_SET)
    )
    if Darwin.fcntl(fd, F_SETLK, &lock) != 0 {
      let err = errno
      _ = Darwin.close(fd)
      // F_SETLK reports contention as EAGAIN on macOS; some kernels
      // alias EWOULDBLOCK to the same value, others use EACCES — the
      // POSIX text allows either. Treat all three as "another owner
      // already holds the lock" and bubble up as `.alreadyHeld`.
      if err == EAGAIN || err == EWOULDBLOCK || err == EACCES {
        throw SessionStoreError.alreadyHeld
      }
      throw SessionStoreError.write("fcntl(F_SETLK, \(fileURL.path)) failed: errno=\(err)")
    }
    self.lockFD = fd
  }

  /// Releases the advisory lock and closes the owning descriptor.
  /// Idempotent — a second call after `release()` (or after `deinit`)
  /// is a no-op. Exposed so callers that intentionally tear down the
  /// store mid-process (tests, second-instance fallback in `bringUp`)
  /// can hand the lock to another owner.
  public func release() {
    guard lockFD >= 0 else { return }
    Self.releaseLock(fd: lockFD)
    lockFD = -1
  }

  nonisolated deinit {
    if lockFD >= 0 {
      Self.releaseLock(fd: lockFD)
    }
  }

  /// Drops the F_WRLCK held on `fd` and closes the descriptor. Shared
  /// by `release()` and `deinit` so the un-lock + close sequence has
  /// one site to keep consistent. `nonisolated` so the
  /// `nonisolated deinit` can reach it without hopping actors —
  /// the underlying syscalls are themselves thread-safe.
  private nonisolated static func releaseLock(fd: Int32) {
    var unlock = Darwin.flock(
      l_start: 0,
      l_len: 0,
      l_pid: 0,
      l_type: Int16(F_UNLCK),
      l_whence: Int16(SEEK_SET)
    )
    _ = Darwin.fcntl(fd, F_SETLK, &unlock)
    _ = Darwin.close(fd)
  }

  /// Read the on-disk catalog. Returns `.empty` for both a missing file
  /// and any decode failure (the corrupt payload is renamed aside so a
  /// user can inspect it after the fact). A `version` higher than the
  /// current schema is treated the same way as a decode failure, except
  /// the file is left untouched on disk — newer touch-code builds may
  /// still own it.
  public func load() throws -> SessionCatalog {
    let fm = FileManager.default
    guard fm.fileExists(atPath: fileURL.path) else { return .empty }

    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      logger.error("Failed to read sessions.json: \(error.localizedDescription, privacy: .public)")
      throw SessionStoreError.decode(error.localizedDescription)
    }

    let decoded: SessionCatalog
    do {
      decoded = try JSONDecoder().decode(SessionCatalog.self, from: data)
    } catch {
      // The corrupt file is renamed rather than deleted so the user can
      // inspect what went wrong and so this code stays crash-free even
      // when on-disk state is hostile.
      logger.error(
        "Failed to decode sessions.json (\(error.localizedDescription, privacy: .public)); backing up corrupt file."
      )
      backupCorruptFile()
      return .empty
    }

    guard decoded.version <= SessionCatalog.currentVersion else {
      // Forward-compat: a future touch-code build wrote a newer schema.
      // Refuse to interpret the payload but leave it on disk so that
      // future build remains the source of truth.
      logger.notice(
        "sessions.json version \(decoded.version) is newer than supported \(SessionCatalog.currentVersion); ignoring."
      )
      return .empty
    }

    return decoded
  }

  /// Coalescing write. The latest `catalog` overrides any earlier
  /// pending value; the timer fires 500 ms after the most-recent call.
  /// An intervening `saveNow(_:)` cancels the pending task and clears
  /// `latestCatalog` — by design, so an explicit save is not undone by a
  /// stale debounce firing afterwards.
  public func scheduleSave(_ catalog: SessionCatalog) {
    latestCatalog = catalog

    pendingSaveTask?.cancel()
    pendingSaveTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      await self.runPendingSave()
    }
  }

  /// Immediate, blocking save. Encodes pretty + sorted keys for stable
  /// diffs in tests and version-control friendliness.
  ///
  /// Cancels any in-flight debounced save before writing. Without this,
  /// a `scheduleSave(stale)` queued earlier could fire 500 ms later and
  /// overwrite the just-written catalog with the older snapshot — making
  /// "saveNow" only stick if no debounce had been scheduled. We clear
  /// `latestCatalog` BEFORE attempting the write so a failed write does
  /// not leave the prior queued value behind: a subsequent `flushPending`
  /// must not re-fire whatever was queued before this call took over.
  /// The caller's snapshot is the source of truth either way; if the
  /// write throws, callers re-attempt via their own paths rather than
  /// relying on the debounce to retry.
  public func saveNow(_ catalog: SessionCatalog) throws {
    pendingSaveTask?.cancel()
    pendingSaveTask = nil
    latestCatalog = nil
    do {
      try AtomicFileStore.write(catalog, to: fileURL)
    } catch {
      throw SessionStoreError.write(error.localizedDescription)
    }
  }

  /// Synchronous flush for app termination. Cancels any pending timer
  /// and writes the most-recent catalog so the last mutation is not
  /// dropped inside the 500 ms debounce window.
  public func flushPending() {
    pendingSaveTask?.cancel()
    pendingSaveTask = nil
    guard let toSave = latestCatalog else { return }
    do {
      try saveNow(toSave)
    } catch {
      logger.error(
        "Failed to flush sessions.json on termination: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func runPendingSave() {
    guard let toSave = latestCatalog else { return }
    do {
      try saveNow(toSave)
    } catch {
      logger.error("Failed to save sessions.json: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func backupCorruptFile() {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let backupURL = fileURL.deletingLastPathComponent()
      .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(timestamp).bak")
    try? FileManager.default.moveItem(at: fileURL, to: backupURL)
  }
}

public enum SessionStoreError: Error, Equatable {
  case decode(String)
  case write(String)
  /// Surfaced when `SessionStore.init` cannot acquire `LOCK_EX` on
  /// `sessions.json` because another touch-code instance already
  /// holds it. The caller is expected to degrade to "no-resume mode"
  /// for the duration of this process.
  case alreadyHeld
}
