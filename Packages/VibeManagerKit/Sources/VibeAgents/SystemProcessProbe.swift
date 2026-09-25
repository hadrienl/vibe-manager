import Foundation
import VibeApplication
import VibeProcess

/// Runs a short, non interactive command and always returns, even if the command hangs.
///
/// It is `BoundedProcess` under the port the detection speaks: the command runs in a process group
/// of its own, and a timeout or a cancellation stops the whole group, so a login shell whose
/// profile starts a helper leaves nothing behind.
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
    let result: BoundedProcessResult
    do {
      result = try await BoundedProcess.run(
        BoundedProcessRequest(
          executablePath: executablePath,
          arguments: arguments,
          environment: environment,
          workingDirectoryPath: workingDirectoryPath,
          timeout: timeout,
          outputByteLimit: outputByteLimit,
          terminationGrace: terminationGrace
        )
      )
    } catch BoundedProcessError.cancelled {
      throw ProbeError.cancelled
    } catch {
      throw ProbeError.launchFailed
    }

    return ProbeResult(
      exitCode: result.exitCode,
      standardOutput: Self.text(result.standardOutput),
      standardError: Self.text(result.standardError),
      didTimeOut: result.didTimeOut
    )
  }

  private static func text(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
