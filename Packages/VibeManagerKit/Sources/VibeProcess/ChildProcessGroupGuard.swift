import Darwin
import Foundation

/// Last resort against orphans: an application that exits without stopping what it started would
/// otherwise leave agents, probes or `git` running with no window to observe them.
///
/// Every child the application spawns leads a process group of its own and is registered here for
/// as long as it may be running; `atexit` kills whatever is still registered, the whole group at
/// once so that a grandchild goes with its parent.
public enum ChildProcessGroupGuard {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var processGroups: Set<pid_t> = []
  nonisolated(unsafe) private static var isInstalled = false

  public static func register(_ processGroup: pid_t) {
    guard processGroup > 0 else { return }
    lock.lock()
    processGroups.insert(processGroup)
    let shouldInstall = !isInstalled
    isInstalled = true
    lock.unlock()

    guard shouldInstall else { return }
    atexit {
      ChildProcessGroupGuard.killRegisteredGroups()
    }
  }

  public static func unregister(_ processGroup: pid_t) {
    lock.lock()
    processGroups.remove(processGroup)
    lock.unlock()
  }

  /// Whether `processGroup` is currently registered. For tests.
  public static func isRegistered(_ processGroup: pid_t) -> Bool {
    lock.withLock { processGroups.contains(processGroup) }
  }

  public static func killRegisteredGroups() {
    lock.lock()
    let groups = processGroups
    processGroups.removeAll()
    lock.unlock()

    for group in groups {
      kill(-group, SIGKILL)
    }
  }
}
