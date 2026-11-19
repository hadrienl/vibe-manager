import Foundation
import Testing
import VibeApplication
import VibeProcess

@testable import VibeComposition

private actor ReportingCLI {
  var calls: [BoundedProcessRequest] = []
  let existing: Bool
  var failuresLeft: Int
  init(existing: Bool = false, failuresLeft: Int = 0) {
    self.existing = existing
    self.failuresLeft = failuresLeft
  }
  func run(_ request: BoundedProcessRequest) -> BoundedProcessResult {
    calls.append(request)
    if request.arguments.contains("create"), failuresLeft > 0 {
      failuresLeft -= 1
      return BoundedProcessResult(termination: .exited(1))
    }
    let output =
      request.arguments.contains("list")
      ? (existing ? "[{\"url\":\"https://github.com/hadrienl/vibe-manager/issues/123\"}]" : "[]")
      : "https://github.com/hadrienl/vibe-manager/issues/123\n"
    return BoundedProcessResult(termination: .exited(0), standardOutput: Data(output.utf8))
  }
}

struct InteractionFailureReporterTests {
  private func failure() -> AnswerAgentRequest.Failure {
    .init(
      requestID: "request-a", outcome: .notOnScreen,
      request: "question with previews", answer: "option 1",
      before: "❯ 1. Relais\n  2. singleTask", after: "same dialog",
      keys: [[49], [13]], writtenKeys: [])
  }

  @Test("Common environment and authorization credentials are masked in every report field")
  func credentialFormats() {
    let credentials = """
      AWS_SECRET_ACCESS_KEY=review-only-fake-value
      export AWS_ACCESS_KEY_ID=AKIAREVIEWONLYFAKE000
      AWS_SESSION_TOKEN='fake session token with spaces'
      Authorization: Basic cmV2aWV3OmZha2U=
      {"Authorization": "Bearer fake-bearer-value"}
      curl --password 'fake cli password' --api-key=fake-cli-key
      {"password": "fake password with spaces", "api_key": "fake-json-key"}
      """
    let failure = AnswerAgentRequest.Failure(
      requestID: "credentials", outcome: .interrupted, request: credentials,
      answer: credentials, before: credentials, after: credentials, keys: [], writtenKeys: [])
    let body = InteractionFailureReporter.body(failure, fingerprint: "credentials")
    for secret in [
      "review-only-fake-value", "AKIAREVIEWONLYFAKE000", "fake session token with spaces",
      "cmV2aWV3OmZha2U=", "fake-bearer-value", "fake cli password", "fake-cli-key",
      "fake password with spaces", "fake-json-key",
    ] {
      #expect(!body.contains(secret))
    }
    #expect(body.contains("AWS_SECRET_ACCESS_KEY="))
    #expect(body.contains("Authorization: Basic [REDACTED]"))
  }

  @Test("A pending report from an earlier version is sanitized and retried after upload failure")
  func pendingReportRetry() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("pending.json")
    let pending = [
      "title": "Legacy failure", "body": "<pre>AWS_SECRET_ACCESS_KEY=legacy-fake-secret</pre>",
    ]
    try JSONSerialization.data(withJSONObject: pending).write(to: file)
    let cli = ReportingCLI(failuresLeft: 1)
    let reporter = InteractionFailureReporter(
      directory: directory, environment: [:], retryDelay: .milliseconds(10),
      run: { await cli.run($0) })
    await reporter.start()
    var posted = false
    for _ in 0..<200 {
      let saved = try String(contentsOf: file, encoding: .utf8)
      if saved.contains("issueURL") {
        posted = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(posted)
    let saved = try String(contentsOf: file, encoding: .utf8)
    #expect(!saved.contains("legacy-fake-secret"))
    let uploads = await cli.calls.filter { $0.arguments.contains("create") }
    #expect(uploads.count == 2)
    for upload in uploads {
      let body = String(decoding: upload.standardInput?.data ?? Data(), as: UTF8.self)
      #expect(!body.contains("legacy-fake-secret"))
      #expect(body.contains("AWS_SECRET_ACCESS_KEY=[REDACTED]</pre>"))
    }
  }

  @Test("Reports preserve terminal text, input and recovery, while masking credentials")
  func reportContent() {
    let failure = AnswerAgentRequest.Failure(
      requestID: "a", outcome: .interrupted, request: #"{"api_key": "private-value"}"#,
      answer: "Bearer private-bearer", before: "ghp_privategithubtoken", after: "❯ 1. Relais",
      keys: [Array("private pasted value".utf8)], writtenKeys: [[49]])
    let body = InteractionFailureReporter.body(failure, fingerprint: "fingerprint")
    for secret in [
      "private-value", "private-bearer", "ghp_privategithubtoken", "private pasted value",
    ] {
      #expect(!body.contains(secret))
    }
    #expect(body.contains("❯ 1. Relais"))
    #expect(body.contains("[49]"))
    #expect(body.contains("terminal view"))
    #expect(body.contains("interaction-failure-fingerprint"))
  }

  @Test("Composed outside the application, nothing is ever reported to GitHub")
  func notFromTests() {
    #expect(
      AppEnvironment.interactionFailureReporter(
        logs: FileManager.default.temporaryDirectory, environment: [:]) == nil)
  }

  @Test("A failure is persisted, posted once and remains deduplicated after restart")
  func durableReport() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = ReportingCLI()
    let reporter = InteractionFailureReporter(
      directory: directory, environment: [:], run: { await cli.run($0) })
    await reporter.enqueue(failure())
    var posted = false
    for _ in 0..<200 {
      if let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil),
        let file = files.first, let text = try? String(contentsOf: file, encoding: .utf8),
        text.contains("issueURL")
      {
        posted = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(posted)
    #expect(await cli.calls.count == 2)
    let restarted = InteractionFailureReporter(
      directory: directory, environment: [:], run: { await cli.run($0) })
    await restarted.enqueue(failure())
    try await Task.sleep(for: .milliseconds(50))
    #expect(await cli.calls.count == 2)
    let calls = await cli.calls
    #expect(calls[1].arguments.contains("--body-file"))
    #expect(calls[1].standardInput?.data.isEmpty == false)
  }

  @Test("An outbox entry left before a crash finds its existing GitHub ticket")
  func existingTicket() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = ReportingCLI(existing: true)
    let reporter = InteractionFailureReporter(
      directory: directory, environment: [:], run: { await cli.run($0) })
    await reporter.enqueue(failure())
    for _ in 0..<200 {
      if await cli.calls.count == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await cli.calls.count == 1)
    #expect(await cli.calls.first?.arguments.contains("list") == true)
  }
}
