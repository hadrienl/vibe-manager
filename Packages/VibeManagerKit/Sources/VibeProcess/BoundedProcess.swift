import Darwin
import Foundation

/// A short, non interactive command to run: a probe, `git`, `xcode-select`.
///
/// The environment and the timeout have no default on purpose. A default environment would be the
/// application's own, secrets and all, and a default timeout is one nobody chose.
public struct BoundedProcessRequest: Sendable {
  public var executablePath: String
  public var arguments: [String]
  public var environment: [String: String]
  public var workingDirectoryPath: String?
  public var timeout: Duration
  /// Bytes kept from each of standard output and standard error. The rest is read and dropped, so
  /// a verbose command never blocks on a full pipe nor fills the application's memory.
  public var outputByteLimit: Int
  /// How long the group is given to leave after `SIGTERM`, before `SIGKILL`.
  public var terminationGrace: Duration
  /// What the command reads. `nil` gives it `/dev/null`, as every command had before.
  public var standardInput: BoundedProcessInput?

  public init(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    workingDirectoryPath: String? = nil,
    timeout: Duration,
    outputByteLimit: Int = BoundedProcess.defaultOutputByteLimit,
    terminationGrace: Duration = .seconds(2),
    standardInput: BoundedProcessInput? = nil
  ) {
    self.standardInput = standardInput
    self.executablePath = executablePath
    self.arguments = arguments
    self.environment = environment
    self.workingDirectoryPath = workingDirectoryPath
    self.timeout = timeout
    self.outputByteLimit = outputByteLimit
    self.terminationGrace = terminationGrace
  }
}

/// The standard input of a bounded command, written as soon as it starts.
public struct BoundedProcessInput: Sendable {
  public var data: Data
  /// When set, the input is kept open until the standard output holds these bytes, then closed.
  /// A server that stops at the end of its input — `codex app-server` — would otherwise stop
  /// before it answered. The timeout still bounds the whole exchange.
  public var closeOnceOutputContains: Data?

  public init(data: Data, closeOnceOutputContains: Data? = nil) {
    self.data = data
    self.closeOnceOutputContains = closeOnceOutputContains
  }
}

/// How a bounded command ended, and what it wrote.
public struct BoundedProcessResult: Hashable, Sendable {
  public enum Termination: Hashable, Sendable {
    case exited(Int32)
    case signalled(Int32)
    /// Stopped because it outlived its timeout.
    case timedOut
  }

  public let termination: Termination
  public let standardOutput: Data
  public let standardError: Data
  /// Whether either stream wrote more than `outputByteLimit`.
  public let outputTruncated: Bool

  public init(
    termination: Termination,
    standardOutput: Data = Data(),
    standardError: Data = Data(),
    outputTruncated: Bool = false
  ) {
    self.termination = termination
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.outputTruncated = outputTruncated
  }

  /// The exit status, the signal number for a command a signal ended — as `Process` reports it —
  /// and -1 for one that timed out.
  public var exitCode: Int32 {
    switch termination {
    case .exited(let code), .signalled(let code): return code
    case .timedOut: return -1
    }
  }

  public var didTimeOut: Bool { termination == .timedOut }
}

public enum BoundedProcessError: Error, Hashable, Sendable {
  /// `posix_spawn` refused, with its error code: a missing or unrunnable executable, a missing
  /// working directory, a process table full.
  case launchFailed(code: Int32)
  case cancelled
}

/// The one way the application runs a command that is not a terminal.
///
/// Every command gets a process group of its own, standard input on `/dev/null`, no descriptor
/// but the three it is given, default signal dispositions, an explicit environment and a timeout.
/// It is registered with `ChildProcessGroupGuard` while it may run, and the group — not only the
/// process — is what is stopped: a login shell whose profile starts a helper, or a `git` that runs
/// one, leaves nothing behind. Once the command has exited, whatever it left in its group is
/// stopped too.
///
/// `Process` is not used: it gives no control over the process group, leaks every descriptor the
/// application has not marked close-on-exec, and only ever signals the one pid.
public enum BoundedProcess {
  public static let defaultOutputByteLimit = 1 << 20

  public static func run(_ request: BoundedProcessRequest) async throws -> BoundedProcessResult {
    let handle = ProcessGroupHandle(grace: request.terminationGrace.secondsValue)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let result = try execute(request, handle: handle)
            if handle.isCancelled {
              continuation.resume(throwing: BoundedProcessError.cancelled)
            } else {
              continuation.resume(returning: result)
            }
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      // Must return at once: the group is stopped on another thread.
      handle.cancel()
    }
  }

  private static func execute(
    _ request: BoundedProcessRequest,
    handle: ProcessGroupHandle
  ) throws -> BoundedProcessResult {
    guard !handle.isCancelled else { throw BoundedProcessError.cancelled }

    var output: [Int32] = [-1, -1]
    var errors: [Int32] = [-1, -1]
    guard pipe(&output) == 0 else { throw BoundedProcessError.launchFailed(code: errno) }
    guard pipe(&errors) == 0 else {
      let code = errno
      close(output[0])
      close(output[1])
      throw BoundedProcessError.launchFailed(code: code)
    }
    var input: [Int32] = [-1, -1]
    if request.standardInput != nil, pipe(&input) != 0 {
      let code = errno
      for descriptor in output + errors { close(descriptor) }
      throw BoundedProcessError.launchFailed(code: code)
    }
    for descriptor in output + errors + input where descriptor >= 0 {
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    let processIdentifier: pid_t
    do {
      processIdentifier = try spawn(
        request, input: input[0] >= 0 ? input[0] : nil, output: output[1], error: errors[1])
    } catch {
      for descriptor in output + errors + input where descriptor >= 0 { close(descriptor) }
      throw error
    }
    close(output[1])
    close(errors[1])
    let writer = request.standardInput.map { InputWriter(descriptor: input[1], input: $0) }
    if input[0] >= 0 { close(input[0]) }

    // The child leads its group: the group identifier is its process identifier.
    let group = processIdentifier
    ChildProcessGroupGuard.register(group)
    // A cancellation that arrived while spawning is applied here.
    handle.adopt(group)
    // Once this returns, a late cancellation must not signal a number another group may have.
    defer { handle.release() }

    let reader = OutputReader(
      descriptors: [output[0], errors[0]], limit: max(0, request.outputByteLimit))
    reader.watchStandardOutput = writer.map { writer in { writer.outputGrew(to: $0) } }
    reader.start()
    writer?.start()
    // However it ends, the input is closed with it.
    defer { writer?.close() }

    // The group stays registered until the child is reaped, whenever that is.
    let exit = ExitWaiter(processIdentifier: processIdentifier) {
      ChildProcessGroupGuard.unregister(group)
    }
    exit.start()

    var timedOut = false
    var reaped = true
    if !exit.wait(seconds: request.timeout.secondsValue) {
      timedOut = true
      handle.stop()
      // A process in an uninterruptible wait — `git` on a stalled network volume — survives even
      // SIGKILL until the kernel lets go. The caller is not held for it: the waiter's thread
      // reaps it whenever that happens.
      reaped = exit.wait(seconds: handle.grace * 2)
    }
    // Whatever the command left in its group goes with it: nothing else will ever collect it.
    if reaped {
      terminateGroup(group, grace: handle.grace)
    }

    // A process that left the group — a daemon that called `setsid` — may still hold a pipe. It is
    // not waited for.
    let streams = reader.finish(within: handle.grace)
    for descriptor in [output[0], errors[0]] { close(descriptor) }

    let termination: BoundedProcessResult.Termination
    if timedOut {
      termination = .timedOut
    } else {
      termination = exit.termination
    }
    return BoundedProcessResult(
      termination: termination,
      standardOutput: streams.data[0],
      standardError: streams.data[1],
      outputTruncated: streams.truncated
    )
  }

  private static func spawn(
    _ request: BoundedProcessRequest,
    input: Int32?,
    output: Int32,
    error: Int32
  ) throws -> pid_t {
    // The posix_spawn family returns its error code and leaves errno alone.
    var fileActions: posix_spawn_file_actions_t?
    var result = posix_spawn_file_actions_init(&fileActions)
    guard result == 0 else { throw BoundedProcessError.launchFailed(code: result) }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    if let input {
      result = posix_spawn_file_actions_adddup2(&fileActions, input, 0)
    } else {
      result = posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
    }
    guard result == 0 else { throw BoundedProcessError.launchFailed(code: result) }
    result = posix_spawn_file_actions_adddup2(&fileActions, output, 1)
    guard result == 0 else { throw BoundedProcessError.launchFailed(code: result) }
    result = posix_spawn_file_actions_adddup2(&fileActions, error, 2)
    guard result == 0 else { throw BoundedProcessError.launchFailed(code: result) }
    if let directory = request.workingDirectoryPath {
      result = posix_spawn_file_actions_addchdir_np(&fileActions, directory)
      guard result == 0 else { throw BoundedProcessError.launchFailed(code: result) }
    }

    var attributes: posix_spawnattr_t?
    result = posix_spawnattr_init(&attributes)
    guard result == 0 else { throw BoundedProcessError.launchFailed(code: result) }
    defer { posix_spawnattr_destroy(&attributes) }

    var defaultedSignals = sigset_t()
    sigfillset(&defaultedSignals)
    posix_spawnattr_setsigdefault(&attributes, &defaultedSignals)
    var unblockedSignals = sigset_t()
    sigemptyset(&unblockedSignals)
    posix_spawnattr_setsigmask(&attributes, &unblockedSignals)
    // A group of its own, led by the child: 0 names the child's pid. Not a session — these
    // commands have no terminal, and must not get one by opening a tty.
    posix_spawnattr_setpgroup(&attributes, 0)
    let flags =
      POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
      | POSIX_SPAWN_SETSIGMASK
    posix_spawnattr_setflags(&attributes, Int16(flags))

    let path = request.executablePath
    let arguments = [path] + request.arguments
    let environment = request.environment.map { "\($0.key)=\($0.value)" }.sorted()

    var processIdentifier: pid_t = 0
    result = withCStrings(arguments) { argv in
      withCStrings(environment) { envp in
        posix_spawn(&processIdentifier, path, &fileActions, &attributes, argv, envp)
      }
    }
    guard result == 0 else { throw BoundedProcessError.launchFailed(code: result) }
    return processIdentifier
  }

  /// `SIGTERM` to the group, then `SIGKILL` to whatever is left after `grace`.
  static func terminateGroup(_ group: pid_t, grace: Double) {
    guard group > 0, kill(-group, SIGTERM) == 0 else { return }
    let deadline = Date().addingTimeInterval(grace)
    while kill(-group, 0) == 0, Date() < deadline {
      usleep(10_000)
    }
    if kill(-group, 0) == 0 {
      kill(-group, SIGKILL)
    }
  }
}

/// The running group, shared with the cancellation handler.
private final class ProcessGroupHandle: @unchecked Sendable {
  private let lock = NSLock()
  let grace: Double
  private var group: pid_t?
  private var cancelled = false

  init(grace: Double) {
    self.grace = grace
  }

  var isCancelled: Bool { lock.withLock { cancelled } }

  func adopt(_ group: pid_t) {
    let shouldStop = lock.withLock {
      self.group = group
      return cancelled
    }
    if shouldStop { stop() }
  }

  func cancel() {
    lock.withLock { cancelled = true }
    DispatchQueue.global(qos: .userInitiated).async { self.stop() }
  }

  func stop() {
    guard let group = lock.withLock({ self.group }) else { return }
    BoundedProcess.terminateGroup(group, grace: grace)
  }

  func release() {
    lock.withLock { group = nil }
  }
}

/// Reaps the child on a thread of its own, so the caller can wait with a deadline.
private final class ExitWaiter: @unchecked Sendable {
  private let processIdentifier: pid_t
  private let onExit: @Sendable () -> Void
  private let exited = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var status: Int32 = 0

  init(processIdentifier: pid_t, onExit: @escaping @Sendable () -> Void) {
    self.processIdentifier = processIdentifier
    self.onExit = onExit
  }

  func start() {
    DispatchQueue.global(qos: .userInitiated).async {
      var status: Int32 = 0
      while waitpid(self.processIdentifier, &status, 0) == -1, errno == EINTR {}
      self.lock.withLock { self.status = status }
      self.onExit()
      self.exited.signal()
    }
  }

  /// Whether the child exited within `seconds`.
  func wait(seconds: Double) -> Bool {
    guard exited.wait(timeout: .now() + seconds) == .success else { return false }
    exited.signal()
    return true
  }

  var termination: BoundedProcessResult.Termination {
    let status = lock.withLock { self.status }
    // WIFEXITED / WTERMSIG are macros Swift does not import.
    let signal = status & 0x7f
    if signal == 0 {
      return .exited((status >> 8) & 0xff)
    }
    return .signalled(signal)
  }
}

/// Drains both pipes from one thread, so a command that fills one never waits on a reader blocked
/// on the other.
private final class OutputReader: @unchecked Sendable {
  struct Streams {
    var data: [Data]
    var truncated: Bool
  }

  private let descriptors: [Int32]
  private let limit: Int
  private let lock = NSLock()
  private var streams: Streams
  /// Told what the standard output holds each time it grows. Set before `start`.
  var watchStandardOutput: ((Data) -> Void)?
  private var abandoned = false
  private let finished = DispatchSemaphore(value: 0)

  init(descriptors: [Int32], limit: Int) {
    self.descriptors = descriptors
    self.limit = limit
    streams = Streams(data: descriptors.map { _ in Data() }, truncated: false)
  }

  func start() {
    DispatchQueue.global(qos: .userInitiated).async {
      self.drain()
      self.finished.signal()
    }
  }

  /// What was read, once both streams ended or `seconds` passed.
  func finish(within seconds: Double) -> Streams {
    if finished.wait(timeout: .now() + seconds) == .timedOut {
      lock.withLock { abandoned = true }
      finished.wait()
    }
    return lock.withLock { streams }
  }

  private func drain() {
    var open = descriptors.map { _ in true }
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while open.contains(true) {
      if lock.withLock({ abandoned }) { return }
      var polled = descriptors.enumerated().map { index, descriptor in
        pollfd(fd: open[index] ? descriptor : -1, events: Int16(POLLIN), revents: 0)
      }
      let ready = poll(&polled, nfds_t(polled.count), 50)
      if ready < 0, errno != EINTR { return }
      guard ready > 0 else { continue }
      for index in polled.indices where open[index] && polled[index].revents != 0 {
        let count = read(descriptors[index], &buffer, buffer.count)
        if count > 0 {
          append(buffer[0..<count], to: index)
        } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
          open[index] = false
        }
      }
    }
  }

  private func append(_ bytes: ArraySlice<UInt8>, to index: Int) {
    let grown = lock.withLock { () -> Data? in
      let room = limit - streams.data[index].count
      if bytes.count > room {
        streams.truncated = true
      }
      if room > 0 {
        streams.data[index].append(contentsOf: bytes.prefix(room))
      }
      return index == 0 ? streams.data[0] : nil
    }
    if let grown { watchStandardOutput?(grown) }
  }
}

/// Writes a command's input on a thread of its own — a pipe holds 64 KiB, and a command that reads
/// only once it has written would otherwise block the writer — and closes it when it is done, or
/// once the output holds what it waits for.
private final class InputWriter: @unchecked Sendable {
  private let descriptor: Int32
  private let input: BoundedProcessInput
  private let lock = NSLock()
  private var isClosed = false
  private var isWritten = false
  private var outputHasMarker = false

  init(descriptor: Int32, input: BoundedProcessInput) {
    self.descriptor = descriptor
    self.input = input
    // A command that exits without reading its input must cost an `EPIPE`, not a `SIGPIPE` that
    // would end the application.
    _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
  }

  func start() {
    DispatchQueue.global(qos: .userInitiated).async {
      self.input.data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let written = write(self.descriptor, bytes.baseAddress! + offset, bytes.count - offset)
          if written < 0 {
            if errno == EINTR { continue }
            break
          }
          offset += written
        }
      }
      let close = self.lock.withLock { () -> Bool in
        self.isWritten = true
        return self.input.closeOnceOutputContains == nil || self.outputHasMarker
      }
      if close { self.close() }
    }
  }

  func outputGrew(to output: Data) {
    guard let marker = input.closeOnceOutputContains, output.range(of: marker) != nil else {
      return
    }
    let close = lock.withLock { () -> Bool in
      outputHasMarker = true
      return isWritten
    }
    if close { self.close() }
  }

  func close() {
    let shouldClose = lock.withLock { () -> Bool in
      defer { isClosed = true }
      return !isClosed
    }
    if shouldClose { Darwin.close(descriptor) }
  }
}

extension Duration {
  fileprivate var secondsValue: Double {
    Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}

private func withCStrings<Result>(
  _ strings: [String],
  _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result
) -> Result {
  var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
  pointers.append(nil)
  defer {
    for pointer in pointers {
      free(pointer)
    }
  }
  return pointers.withUnsafeMutableBufferPointer { buffer in
    body(buffer.baseAddress)
  }
}
