import Foundation
import VibeApplication
import VibeDomain

/// Appends what the gateway observes to the journal of the session a token belongs to.
public actor GatewayStepJournal: GatewayObserving {
  private let directory: URL
  private let session: @Sendable (String) async -> SessionID?
  private let now: @Sendable () -> Date

  public init(
    directory: URL, session: @escaping @Sendable (String) async -> SessionID?,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.directory = directory
    self.session = session
    self.now = now
  }

  public func retrying(
    token: String, attempt: Int, of maximum: Int, after delay: Duration, failure: EndpointFailure
  ) async {
    let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
    await append(
      GatewayStepRecord(
        date: now(), kind: .retry, attempt: attempt, maximum: maximum, delaySeconds: seconds,
        failure: failure.kind.rawValue, status: failure.status),
      token: token)
  }

  public func serverStep(token: String, step: CanonicalServerStep) async {
    await append(
      GatewayStepRecord(
        date: now(), kind: .step, name: step.name, input: GatewayStepRecord.cut(step.input),
        output: GatewayStepRecord.cut(step.output)),
      token: token)
  }

  private func append(_ record: GatewayStepRecord, token: String) async {
    guard let session = await session(token),
      var line = try? GatewayStepRecord.encoder.encode(record)
    else { return }
    line.append(UInt8(ascii: "\n"))
    let url = GatewayStepRecord.file(for: session, in: directory)
    let folder = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: line)
    } else {
      FileManager.default.createFile(
        atPath: url.path, contents: line, attributes: [.posixPermissions: 0o600])
    }
  }
}
