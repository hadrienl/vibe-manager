import Foundation
import VibeApplication

/// Runs a short, non interactive command and always returns, even if the command hangs.
///
/// The whole process lifetime stays inside a single background closure: nothing that Foundation
/// does not declare as `Sendable` crosses a concurrency boundary.
public struct SystemProcessProbe: ProcessProbe {
  private let outputByteLimit: Int
  private let terminationGrace: Duration

  public init(outputByteLimit: Int = 64 * 1024, terminationGrace: Duration = .milliseconds(500)) {
    self.outputByteLimit = outputByteLimit
    self.terminationGrace = terminationGrace
  }

  public func run(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    workingDirectoryPath: String?,
    timeout: Duration
  ) async throws -> ProbeResult {
    let limit = outputByteLimit
    let graceSeconds = terminationGrace.seconds
    let timeoutSeconds = timeout.seconds
    let handle = RunningProcess(graceSeconds: graceSeconds)

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let result = try Self.execute(
              executablePath: executablePath,
              arguments: arguments,
              environment: environment,
              workingDirectoryPath: workingDirectoryPath,
              timeoutSeconds: timeoutSeconds,
              graceSeconds: graceSeconds,
              outputByteLimit: limit,
              handle: handle
            )
            if handle.isCancelled {
              continuation.resume(throwing: ProbeError.cancelled)
            } else {
              continuation.resume(returning: result)
            }
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      // Stop waiting and reap the child instead of holding the caller for the full timeout.
      handle.cancel()
    }
  }

  private static func execute(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    workingDirectoryPath: String?,
    timeoutSeconds: Double,
    graceSeconds: Double,
    outputByteLimit: Int,
    handle: RunningProcess
  ) throws -> ProbeResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.environment = environment
    if let workingDirectoryPath {
      process.currentDirectoryURL = URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
    }

    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError
    process.standardInput = FileHandle.nullDevice

    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }

    do {
      try process.run()
    } catch {
      throw ProbeError.launchFailed
    }
    // A cancellation that arrived before the process existed is applied here.
    handle.adopt(process)

    let collector = OutputCollector(limit: outputByteLimit)
    let readers = DispatchGroup()
    collector.read(standardOutput.fileHandleForReading, as: .output, in: readers)
    collector.read(standardError.fileHandleForReading, as: .error, in: readers)

    var didTimeOut = false
    if exited.wait(timeout: .now() + timeoutSeconds) == .timedOut {
      didTimeOut = true
      handle.stop()
      _ = exited.wait(timeout: .now() + graceSeconds + graceSeconds)
    }
    _ = readers.wait(timeout: .now() + graceSeconds)

    return ProbeResult(
      exitCode: didTimeOut ? -1 : process.terminationStatus,
      standardOutput: collector.text(for: .output),
      standardError: collector.text(for: .error),
      didTimeOut: didTimeOut
    )
  }
}

/// Shared handle on the running child, so a cancellation from the calling task can reap it.
final class RunningProcess: @unchecked Sendable {
  private let lock = NSLock()
  private let graceSeconds: Double
  private var process: Process?
  private var cancelled = false

  init(graceSeconds: Double) {
    self.graceSeconds = graceSeconds
  }

  var isCancelled: Bool {
    lock.withLock { cancelled }
  }

  func adopt(_ process: Process) {
    let shouldStop = lock.withLock {
      self.process = process
      return cancelled
    }
    if shouldStop {
      stop()
    }
  }

  /// Called from the cancellation handler, so it must return immediately.
  func cancel() {
    lock.withLock { cancelled = true }
    DispatchQueue.global(qos: .userInitiated).async { self.stop() }
  }

  /// Graceful termination first, then SIGKILL for a child that ignores SIGTERM.
  func stop() {
    guard let process = lock.withLock({ self.process }), process.isRunning else { return }

    process.terminate()
    let deadline = Date().addingTimeInterval(graceSeconds)
    while process.isRunning, Date() < deadline {
      usleep(10_000)
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
    }
  }
}

/// Drains both pipes concurrently so a verbose command cannot deadlock on a full buffer.
private final class OutputCollector: @unchecked Sendable {
  enum Stream {
    case output
    case error
  }

  private let limit: Int
  private let lock = NSLock()
  private var buffers: [Stream: Data] = [:]

  init(limit: Int) {
    self.limit = limit
  }

  func read(_ handle: FileHandle, as stream: Stream, in group: DispatchGroup) {
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async { [limit] in
      defer { group.leave() }
      let data = (try? handle.readToEnd()) ?? Data()
      self.lock.lock()
      self.buffers[stream] = data.prefix(limit)
      self.lock.unlock()
    }
  }

  func text(for stream: Stream) -> String {
    lock.lock()
    let data = buffers[stream] ?? Data()
    lock.unlock()
    return String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension OutputCollector.Stream: Hashable {}
