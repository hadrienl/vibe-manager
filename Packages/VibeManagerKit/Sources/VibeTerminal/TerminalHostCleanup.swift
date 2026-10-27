import Darwin
import Foundation
import os

/// The runtime directories of `$TMPDIR/vibe-manager`, one per data directory, and what to do with
/// the ones nobody lives in any more (#437). An application, a test run or a throwaway copy each
/// leaves one behind when it stops; nothing else ever removed them.
extension TerminalHostLocation {
  /// Held by the application for as long as it runs: the kernel lets go of it when the process
  /// ends, however it ends, so a locked file means a live owner and an unlocked one never lies
  /// the way a recorded process number could.
  var ownerLockPath: String {
    directory.appendingPathComponent("owner.lock").path
  }

  private static let claims = OSAllocatedUnfairLock<[String: Int32]>(initialState: [:])

  /// Declares this process the owner of the directory, for the rest of its life.
  @discardableResult
  public func claim() -> Bool {
    guard (try? prepare()) != nil else { return false }
    return Self.claims.withLock { claims in
      if claims[directory.path] != nil { return true }
      let descriptor = open(ownerLockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { return false }
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        close(descriptor)
        return false
      }
      claims[directory.path] = descriptor
      return true
    }
  }
}

public enum TerminalHostCleanup {
  /// A directory touched more recently than this is left alone: its owner may be between creating
  /// it and taking its locks.
  public static let gracePeriod: TimeInterval = 3600

  /// Removes the directories of `root` that no live process owns, and returns their names. The
  /// `keeping` directory — the caller's own — and anything that is not a directory are never
  /// touched.
  @discardableResult
  public static func removeAbandoned(
    in root: URL, keeping: URL? = nil, now: Date = Date(),
    gracePeriod: TimeInterval = TerminalHostCleanup.gracePeriod
  ) -> [String] {
    let manager = FileManager.default
    guard
      let names = try? manager.contentsOfDirectory(atPath: root.path)
    else { return [] }
    let kept = keeping?.standardizedFileURL.path
    var removed: [String] = []
    for name in names {
      let url = root.appendingPathComponent(name, isDirectory: true)
      guard url.standardizedFileURL.path != kept,
        let attributes = try? manager.attributesOfItem(atPath: url.path),
        attributes[.type] as? FileAttributeType == .typeDirectory,
        let modified = attributes[.modificationDate] as? Date,
        now.timeIntervalSince(modified) > gracePeriod,
        !hasLiveOwner(url)
      else { continue }
      if (try? manager.removeItem(at: url)) != nil { removed.append(name) }
    }
    return removed
  }

  /// Whether a host or an application lives in `directory`.
  static func hasLiveOwner(_ directory: URL) -> Bool {
    for lock in ["host.lock", "owner.lock"]
    where isLocked(directory.appendingPathComponent(lock).path) {
      return true
    }
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    // The sockets of applications that predate `owner.lock`, and of the companion's link.
    for entry in entries where entry.hasSuffix(".sock") {
      if let descriptor = UnixSocket.connect(to: directory.appendingPathComponent(entry).path) {
        close(descriptor)
        return true
      }
    }
    return false
  }

  /// Whether another process holds the lock. Taken and let go at once when nobody does; a host
  /// starting at that very moment waits for it (`TerminalHost.run`).
  private static func isLocked(_ path: String) -> Bool {
    let descriptor = open(path, O_RDWR | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
      flock(descriptor, LOCK_UN)
      return false
    }
    return errno == EWOULDBLOCK
  }
}
