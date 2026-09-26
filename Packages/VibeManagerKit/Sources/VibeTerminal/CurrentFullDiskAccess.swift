import Darwin
import Dispatch
import Foundation
import VibeApplication

/// The application's binary in its third mode: `--probe-full-disk-access` answers whether a
/// process born now, answering for itself, has Full Disk Access, and exits.
///
/// A running process cannot learn it about itself: TCC settles the access once for the process
/// responsible, at its start, and never again while it runs (#76). Asking a fresh process is the
/// only way to know whether the switch has been turned on since.
public enum FullDiskAccessProbeCommand {
  public static let argument = "--probe-full-disk-access"

  /// Exit codes: `0` granted, `1` not granted.
  static let grantedCode: Int32 = 0
  static let notGrantedCode: Int32 = 1

  /// Probes and exits when the arguments ask for it; returns at once otherwise. Called before
  /// anything of the application is set up, like the terminal host.
  public static func runIfRequested(
    arguments: [String] = CommandLine.arguments,
    probe: @autoclosure () -> any FullDiskAccessProbe
  ) {
    guard arguments.contains(argument) else { return }
    exit(exitCode(for: probe()))
  }

  static func exitCode(for probe: any FullDiskAccessProbe) -> Int32 {
    let answer = Answer()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
      answer.set(await probe.status())
      done.signal()
    }
    done.wait()
    return answer.value == .granted ? grantedCode : notGrantedCode
  }

  private final class Answer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FullDiskAccessStatus?

    var value: FullDiskAccessStatus? { lock.withLock { stored } }

    func set(_ status: FullDiskAccessStatus) { lock.withLock { stored = status } }
  }
}

/// Asks a process born now whether the application's identity has Full Disk Access.
///
/// It spawns the application's own binary with `--probe-full-disk-access`, disclaiming
/// responsibility exactly as the terminal host is spawned: the child answers for itself to TCC,
/// under the application's identity, with whatever that identity has been granted by now. A child
/// that answered to this process would inherit this process's frozen answer, and say nothing new.
///
/// Never in the way: the first launch of a freshly built binary that answers for itself waits for
/// the system to assess it, seconds after a rebuild (ADR 0017), so the probe is bounded, and no
/// answer is `nil`.
public struct SpawnedFullDiskAccessProbe: CurrentFullDiskAccessProbe {
  private let executableURL: URL
  private let timeout: Duration
  private let disclaimsResponsibility: Bool

  public init(
    executableURL: URL, timeout: Duration = .seconds(10), disclaimsResponsibility: Bool = true
  ) {
    self.executableURL = executableURL
    self.timeout = timeout
    self.disclaimsResponsibility = disclaimsResponsibility
  }

  /// The application's own binary.
  public static func bundled() -> SpawnedFullDiskAccessProbe? {
    Bundle.main.executableURL.map { SpawnedFullDiskAccessProbe(executableURL: $0) }
  }

  public func status() async -> FullDiskAccessStatus? {
    guard let processIdentifier = spawn() else { return nil }
    let deadline = ContinuousClock.now + timeout
    var status: Int32 = 0
    while true {
      let reaped = waitpid(processIdentifier, &status, WNOHANG)
      if reaped == processIdentifier { break }
      // Given up on — no answer in time, or nobody waiting for one any more (a settings tab closed
      // mid-probe): the child is stopped and reaped, never left to spin on.
      guard reaped == 0, ContinuousClock.now < deadline, !Task.isCancelled else {
        if reaped == 0 {
          kill(processIdentifier, SIGKILL)
          waitpid(processIdentifier, &status, 0)
        }
        return nil
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    // Exited normally, rather than killed by a signal: the low seven bits are zero.
    guard status & 0x7f == 0 else { return nil }
    switch (status >> 8) & 0xff {
    case FullDiskAccessProbeCommand.grantedCode: return .granted
    case FullDiskAccessProbeCommand.notGrantedCode: return .notGranted
    default: return nil
    }
  }

  private func spawn() -> pid_t? {
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    for descriptor in Int32(0)...Int32(2) {
      posix_spawn_file_actions_addopen(
        &fileActions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
    }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaultedSignals = sigset_t()
    sigfillset(&defaultedSignals)
    posix_spawnattr_setsigdefault(&attributes, &defaultedSignals)
    var unblockedSignals = sigset_t()
    sigemptyset(&unblockedSignals)
    posix_spawnattr_setsigmask(&attributes, &unblockedSignals)
    let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
    posix_spawnattr_setflags(&attributes, Int16(flags))
    if disclaimsResponsibility {
      ResponsibilityDisclaimer.apply(to: &attributes)
    }

    let path = executableURL.path
    let environment = ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH"].compactMap { key in
      ProcessInfo.processInfo.environment[key].map { "\(key)=\($0)" }
    }
    var processIdentifier: pid_t = 0
    let result = withCStrings([path, FullDiskAccessProbeCommand.argument]) { argv in
      withCStrings(environment) { envp in
        posix_spawn(&processIdentifier, path, &fileActions, &attributes, argv, envp)
      }
    }
    return result == 0 ? processIdentifier : nil
  }
}
