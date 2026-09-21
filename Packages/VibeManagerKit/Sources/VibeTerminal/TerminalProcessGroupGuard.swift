import Darwin
import Foundation

// Last resort against orphans: an application that exits without stopping its sessions would
// otherwise leave agent processes running with no window to observe them.
enum TerminalProcessGroupGuard {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var processGroups: Set<pid_t> = []
  nonisolated(unsafe) private static var isInstalled = false

  static func register(_ processGroup: pid_t) {
    guard processGroup > 0 else { return }
    lock.lock()
    processGroups.insert(processGroup)
    let shouldInstall = !isInstalled
    isInstalled = true
    lock.unlock()

    guard shouldInstall else { return }
    atexit {
      TerminalProcessGroupGuard.killRegisteredGroups()
    }
  }

  static func unregister(_ processGroup: pid_t) {
    lock.lock()
    processGroups.remove(processGroup)
    lock.unlock()
  }

  static func killRegisteredGroups() {
    lock.lock()
    let groups = processGroups
    processGroups.removeAll()
    lock.unlock()

    for group in groups {
      kill(-group, SIGKILL)
    }
  }
}
