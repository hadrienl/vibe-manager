import Darwin
import Foundation

/// A child that runs for as long as its caller wants and talks through its standard input and
/// output: a bridge to a simulator or an emulator (#480).
///
/// Launched as `BoundedProcess` launches: a process group of its own, no descriptor but its three,
/// default signal dispositions, an explicit environment, standard error on `/dev/null`. It has no
/// timeout: `stop()` ends it, as does the application's exit through `ChildProcessGroupGuard`, and
/// a bridge leaves by itself once its input closes.
public final class StreamingProcess: @unchecked Sendable {
  /// What the child reads. A write once it has left fails, and never raises `SIGPIPE`.
  public let input: FileHandle
  /// What the child writes, at its end once the child has left.
  public let output: FileHandle
  public let processIdentifier: pid_t
  private let grace: Double
  private let exit = ExitState()

  public init(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    terminationGrace: Duration = .seconds(1)
  ) throws {
    var input: [Int32] = [-1, -1]
    var output: [Int32] = [-1, -1]
    guard pipe(&input) == 0 else { throw BoundedProcessError.launchFailed(code: errno) }
    guard pipe(&output) == 0 else {
      let code = errno
      for descriptor in input { close(descriptor) }
      throw BoundedProcessError.launchFailed(code: code)
    }
    for descriptor in input + output {
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }
    _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
    do {
      processIdentifier = try BoundedProcess.spawn(
        path: executablePath, arguments: arguments, environment: environment,
        workingDirectoryPath: nil, input: input[0], output: output[1], error: nil)
    } catch {
      for descriptor in input + output { close(descriptor) }
      throw error
    }
    close(input[0])
    close(output[1])
    self.input = FileHandle(fileDescriptor: input[1], closeOnDealloc: true)
    self.output = FileHandle(fileDescriptor: output[0], closeOnDealloc: true)
    grace =
      Double(terminationGrace.components.seconds)
      + Double(terminationGrace.components.attoseconds) / 1e18

    // The child leads its group, registered until it is reaped, whenever that is.
    let group = processIdentifier
    let exit = exit
    ChildProcessGroupGuard.register(group)
    DispatchQueue.global(qos: .utility).async {
      var status: Int32 = 0
      while waitpid(group, &status, 0) == -1, errno == EINTR {}
      exit.markReaped()
      ChildProcessGroupGuard.unregister(group)
    }
  }

  deinit {
    stop()
  }

  /// Whether the child has left and been reaped.
  public var hasExited: Bool { exit.isReaped }

  /// Closes the child's input, then stops its group: `SIGTERM`, `SIGKILL` after the grace period.
  /// Returns at once.
  public func stop() {
    try? input.close()
    let group = processIdentifier
    let grace = grace
    let exit = exit
    DispatchQueue.global(qos: .utility).async {
      // Once reaped, the number may already be another group's.
      guard !exit.isReaped else { return }
      BoundedProcess.terminateGroup(group, grace: grace)
    }
  }
}

private final class ExitState: @unchecked Sendable {
  private let lock = NSLock()
  private var reaped = false

  var isReaped: Bool { lock.withLock { reaped } }

  func markReaped() {
    lock.withLock { reaped = true }
  }
}
