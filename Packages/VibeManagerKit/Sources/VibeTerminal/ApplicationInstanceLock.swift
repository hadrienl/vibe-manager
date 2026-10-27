import Darwin
import Foundation

/// The one application allowed on a data directory (#436).
///
/// Two applications on the same data folder share its runtime directory: the second takes the web
/// view's socket from the first, and talks to the first one's terminal host. The lock is taken
/// before anything is composed, so the second leaves without touching either. The kernel lets go
/// of it when its holder dies: a crash leaves no lock behind.
public final class ApplicationInstanceLock: Sendable {
  public enum Outcome: Sendable {
    case acquired(ApplicationInstanceLock)
    /// Another application holds it: its process, when it said which one.
    case held(by: pid_t?)
  }

  private let descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    close(descriptor)
  }

  /// Takes the lock of `location`, or says who holds it. `nil` when it could not be checked — a
  /// directory that cannot be made, a file that cannot be opened: the launch goes on regardless.
  public static func acquire(at location: TerminalHostLocation) -> Outcome? {
    guard (try? location.prepare()) != nil else { return nil }
    let descriptor = open(location.instanceLockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return nil }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let holder = Self.readHolder(descriptor)
      close(descriptor)
      return .held(by: holder)
    }
    let text = Data(String(getpid()).utf8)
    ftruncate(descriptor, 0)
    _ = text.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
    return .acquired(ApplicationInstanceLock(descriptor: descriptor))
  }

  private static func readHolder(_ descriptor: Int32) -> pid_t? {
    var buffer = [UInt8](repeating: 0, count: 16)
    let count = pread(descriptor, &buffer, buffer.count, 0)
    guard count > 0 else { return nil }
    return pid_t(String(decoding: buffer.prefix(count), as: UTF8.self))
  }
}

extension TerminalHostLocation {
  var instanceLockPath: String {
    directory.appendingPathComponent("app.lock").path
  }
}
