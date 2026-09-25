import Darwin
import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeProcess

@testable import VibeBrowser

nonisolated(unsafe) private var fixtureAnchor = 0

@MainActor
private final class RecordingRunner: BrowserToolRunning {
  var sessions: [SessionID] = []

  func run(tool: String, arguments: JSONValue, session: SessionID) async -> BrowserToolResult {
    sessions.append(session)
    return .text("ran \(tool)")
  }
}

@Suite("The channel between an agent's bridge and the application", .serialized)
@MainActor
struct BrowserChannelTests {
  private static func fixtureURL() throws -> URL {
    var info = Dl_info()
    let found = withUnsafeMutablePointer(to: &fixtureAnchor) { dladdr($0, &info) }
    try #require(found != 0 && info.dli_fname != nil)
    var url = URL(fileURLWithPath: String(cString: info.dli_fname))
    while url.pathComponents.count > 1, url.pathExtension != "xctest" {
      url.deleteLastPathComponent()
    }
    let fixture = url.deletingLastPathComponent().appendingPathComponent("VibeBrowserBridgeFixture")
    try #require(FileManager.default.isExecutableFile(atPath: fixture.path))
    return fixture
  }

  /// A short path: `sun_path` holds 104 bytes.
  private static func socketPath() -> String {
    "/tmp/vbb-\(UUID().uuidString.prefix(8)).sock"
  }

  /// This test process, as a session's terminal: the bridge it starts descends from it.
  private static func thisProcess(as session: SessionID) throws -> SessionProcess {
    let entry = try #require(ProcessAncestry.entry(of: getpid()))
    return SessionProcess(
      sessionID: session, processIdentifier: entry.processIdentifier,
      startedAt: ProcessStartTime(
        seconds: entry.startSeconds, microseconds: entry.startMicroseconds))
  }

  /// Starts the bridge, writes `lines` to it, and reads back as many answers as there are requests.
  private func exchange(socket: String, lines: [String], answers: Int) async throws -> [JSONValue] {
    let process = Process()
    process.executableURL = try Self.fixtureURL()
    process.arguments = [socket]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    for line in lines {
      try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }
    let reader = output.fileHandleForReading
    let collected = await Task.detached { () -> [JSONValue] in
      var values: [JSONValue] = []
      var buffer = Data()
      while values.count < answers {
        let chunk = reader.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
          let line = buffer[buffer.startIndex..<newline]
          buffer = Data(buffer[(newline + 1)...])
          if let value = try? JSONDecoder().decode(JSONValue.self, from: line) {
            values.append(value)
          }
        }
      }
      return values
    }.value
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    return collected
  }

  private let call =
    #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"tabs_list","arguments":{}}}"#

  @Test("A bridge started from a session's terminal reaches that session's tools")
  func accepted() async throws {
    let session = SessionID()
    let runner = RecordingRunner()
    let path = Self.socketPath()
    let process = try Self.thisProcess(as: session)
    let listener = BrowserChannelListener(
      socketPath: path,
      prepare: {
        // Nothing to prepare in a test.
      }, runner: runner,
      sessions: { [process] })
    try listener.start()
    defer { listener.stop() }

    let answers = try await exchange(
      socket: path,
      lines: [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#, call], answers: 2)
    #expect(answers.count == 2)
    #expect(
      answers.first { $0["id"] == 2 }?["result"]?["content"] == [
        ["type": "text", "text": "ran tabs_list"]
      ])
    #expect(runner.sessions == [session])
  }

  @Test("A process from nowhere is refused, and its bridge says the web view is not there")
  func refused() async throws {
    let runner = RecordingRunner()
    let path = Self.socketPath()
    let stranger = SessionProcess(
      sessionID: SessionID(), processIdentifier: 1,
      startedAt: ProcessStartTime(seconds: 0, microseconds: 0))
    let listener = BrowserChannelListener(
      socketPath: path,
      prepare: {
        // Nothing to prepare in a test.
      }, runner: runner,
      sessions: { [stranger] })
    try listener.start()
    defer { listener.stop() }

    let answers = try await exchange(socket: path, lines: [call], answers: 1)
    #expect(answers.first?["result"]?["isError"] == true)
    #expect(runner.sessions.isEmpty)
  }

  @Test("With the application closed, the bridge still lists its tools and says why a call fails")
  func applicationClosed() async throws {
    let answers = try await exchange(
      socket: Self.socketPath(),
      lines: [#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, call], answers: 2)
    let list = try #require(answers.first { $0["id"] == 1 })
    guard case .array(let tools) = list["result"]?["tools"] ?? .null else {
      Issue.record("no tools")
      return
    }
    #expect(tools.count == BrowserToolCatalog.tools.count)
    let failed = try #require(answers.first { $0["id"] == 2 })
    #expect(failed["result"]?["isError"] == true)
    #expect(
      failed["result"]?["content"]
        == [["type": "text", "text": .string(BrowserBridge.closedMessage)]])
  }
}
