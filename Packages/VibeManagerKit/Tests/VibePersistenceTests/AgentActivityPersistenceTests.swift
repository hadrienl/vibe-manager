import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

private func temporaryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("vibe-activity-log-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func append(_ text: String, to url: URL) throws {
  let handle = try FileHandle(forWritingTo: url)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data(text.utf8))
  try handle.close()
}

/// The next `count` events, or what arrived before the deadline.
private func take(
  _ count: Int,
  from stream: AsyncStream<(AgentActivityEvent, AgentActivityLogPosition)>,
  within timeout: Duration = .seconds(3)
) async -> [(AgentActivityEvent, AgentActivityLogPosition)] {
  let taken = Taken()
  await withTaskGroup(of: Void.self) { group in
    group.addTask {
      for await item in stream {
        if taken.append(item) >= count { break }
      }
    }
    group.addTask { try? await Task.sleep(for: timeout) }
    await group.next()
    group.cancelAll()
  }
  return taken.items
}

/// What `take` has read so far, kept when its deadline passes.
private final class Taken: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [(AgentActivityEvent, AgentActivityLogPosition)] = []

  var items: [(AgentActivityEvent, AgentActivityLogPosition)] {
    lock.withLock { storage }
  }

  /// Adds `item` and says how many there are now.
  func append(_ item: (AgentActivityEvent, AgentActivityLogPosition)) -> Int {
    lock.withLock {
      storage.append(item)
      return storage.count
    }
  }
}

/// Two hooks around a rotation: one that opened the log before it was moved aside and writes to
/// it afterwards, then the next one, whose append creates the log again. They run on a thread of
/// their own — not on the cooperative pool, which a busy runner can hold for many seconds — once
/// the log has been moved aside.
private final class RotationHooks: @unchecked Sendable {
  private let url: URL
  private let lateHook: FileHandle
  private let lock = NSLock()
  private var rotated = false

  init(log url: URL) throws {
    self.url = url
    lateHook = try FileHandle(forWritingTo: url)
  }

  /// Whether the log was seen moved aside, and both hooks wrote.
  var sawRotation: Bool { lock.withLock { rotated } }

  func start() {
    Thread { self.run() }.start()
  }

  private func run() {
    // Ten seconds of looking, however long the machine takes to give the thread its turns.
    var attempts = 0
    while FileManager.default.fileExists(atPath: url.path), attempts < 5_000 {
      attempts += 1
      usleep(2_000)
    }
    defer { try? lateHook.close() }
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      try lateHook.seekToEnd()
      try lateHook.write(contentsOf: Data("Late\t2\t\n".utf8))
    } catch { return }
    FileManager.default.createFile(
      atPath: url.path, contents: Data("Next\t3\t\n".utf8), attributes: [.posixPermissions: 0o644])
    lock.withLock { rotated = true }
  }
}

@Suite("The agent activity log")
struct FileAgentActivityLogTests {
  @Test("A prepared log is empty, private, and emptied again for the next process")
  func prepare() async throws {
    let directory = try temporaryDirectory().appendingPathComponent("AgentActivity")
    let logs = FileAgentActivityLog(directory: directory)
    let id = SessionID()
    let url = try await logs.prepareLog(for: id)
    try append("Stop\t1\t\n", to: url)
    #expect(try await logs.prepareLog(for: id) == url)
    #expect(try Data(contentsOf: url).isEmpty)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect(await logs.existingLog(for: id) == url)
  }

  @Test("Lines arrive as they are appended, a half-written one once it is finished")
  func follows() async throws {
    let logs = FileAgentActivityLog(directory: try temporaryDirectory())
    let id = SessionID()
    let url = try await logs.prepareLog(for: id)
    try append("SessionStart\t1790330464\t{\"transcript_path\":\"/t\"}\n", to: url)
    let stream = await logs.events(for: id, from: nil)
    try append("Sto", to: url)
    try await Task.sleep(for: .milliseconds(100))
    try append("p\t1790330470\t\nnot a line\n", to: url)

    let events = await take(2, from: stream)
    #expect(events.map(\.0.name) == ["SessionStart", "Stop"])
    #expect(events.first?.0.date == Date(timeIntervalSince1970: 1_790_330_464))
    #expect(events.first?.0.payload == Data(#"{"transcript_path":"/t"}"#.utf8))
    #expect(events.last?.0.payload == nil)
    #expect(
      events.last?.1.offset
        == UInt64(
          "SessionStart\t1790330464\t{\"transcript_path\":\"/t\"}\nStop\t1790330470\t\n".utf8.count)
    )
  }

  @Test("Reading resumes where it stopped, and starts over in a file that is not the same one")
  func resumes() async throws {
    let logs = FileAgentActivityLog(directory: try temporaryDirectory())
    let id = SessionID()
    let url = try await logs.prepareLog(for: id)
    try append("A\t1\t\nB\t2\t\n", to: url)
    let first = await take(1, from: await logs.events(for: id, from: nil))
    let position = try #require(first.first?.1)

    let resumed = await take(1, from: await logs.events(for: id, from: position))
    #expect(resumed.map(\.0.name) == ["B"])

    _ = try await logs.prepareLog(for: id)
    try append("C\t3\t\n", to: url)
    let fresh = await take(1, from: await logs.events(for: id, from: position))
    #expect(fresh.map(\.0.name) == ["C"])
  }

  @Test("A log past its size is moved aside, and the next one is followed from its start")
  func rotates() async throws {
    let directory = try temporaryDirectory()
    // The hooks below write on a thread of their own, as they would from their own processes: the
    // grace only has to outlast that thread being scheduled, not the test's task.
    let logs = FileAgentActivityLog(
      directory: directory, rotationThreshold: 16, rotationGrace: .seconds(10))
    let id = SessionID()
    let url = try await logs.prepareLog(for: id)
    let hooks = try RotationHooks(log: url)
    try append("Long\t1\t0123456789\n", to: url)
    hooks.start()
    let stream = await logs.events(for: id, from: nil)
    let read = await take(3, from: stream, within: .seconds(30))
    #expect(hooks.sawRotation)
    #expect(read.map(\.0.name) == ["Long", "Late", "Next"])
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test("Removing a session's log removes it")
  func remove() async throws {
    let logs = FileAgentActivityLog(directory: try temporaryDirectory())
    let id = SessionID()
    let url = try await logs.prepareLog(for: id)
    await logs.removeLog(for: id)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(await logs.existingLog(for: id) == nil)
  }
}

@Suite("The agent activity document")
struct FileAgentActivityStateStoreTests {
  @Test("What is written is read back, keyed by the plain session identifier")
  func roundTrip() async throws {
    let url = try temporaryDirectory().appendingPathComponent("agent-activity.json")
    let store = FileAgentActivityStateStore(url: url)
    let id = SessionID()
    let activity = PersistedAgentActivity(
      activity: .awaitingUser(.approval), unreadSince: Date(timeIntervalSince1970: 1_000.5),
      log: AgentActivityLogPosition(fileIdentifier: 42, offset: 7), isConfirmed: true,
      sourceEvent: PersistedAgentActivityEvent(
        AgentActivityEvent(
          name: "SessionStart", date: Date(timeIntervalSince1970: 900),
          payload: Data(#"{"transcript_path":"/t.jsonl"}"#.utf8))))
    await store.write([id: activity])
    #expect(await store.read() == [id: activity])
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains(id.rawValue.uuidString))
    #expect(text.contains("awaitingUser.approval"))
  }

  @Test("A document written before a field existed reads it as its safe default")
  func olderDocument() async throws {
    let url = try temporaryDirectory().appendingPathComponent("agent-activity.json")
    let id = SessionID()
    try Data(
      #"{"schemaVersion":1,"sessions":{"\#(id.rawValue.uuidString)":{"activity":"working"}}}"#.utf8
    ).write(to: url)
    let read = await FileAgentActivityStateStore(url: url).read()[id]
    #expect(read?.activity == .working)
    #expect(read?.isConfirmed == false)
    #expect(read?.sourceEvent == nil)
  }

  @Test("A damaged or foreign document reads as nothing, and nothing to keep removes it")
  func damaged() async throws {
    let url = try temporaryDirectory().appendingPathComponent("agent-activity.json")
    let store = FileAgentActivityStateStore(url: url)
    try Data("{ not json".utf8).write(to: url)
    #expect(await store.read().isEmpty)
    try Data(#"{"schemaVersion":99,"sessions":{}}"#.utf8).write(to: url)
    #expect(await store.read().isEmpty)
    await store.write([:])
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }
}

@Test("The consent to a CLI's hooks is kept per CLI, and a key never written reads as no decision")
func hookConsentStore() {
  let suite = "vibe-tests-\(UUID().uuidString)"
  defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
  let store = UserDefaultsAgentHookConsentStore(suiteName: suite)
  let codex = AgentProviderID("codex")
  #expect(store.approvedFingerprint(for: codex) == nil)
  #expect(!store.isDeclined(codex))
  store.setApprovedFingerprint("abc", for: codex)
  store.setDeclined(true, for: codex)
  let reread = UserDefaultsAgentHookConsentStore(suiteName: suite)
  #expect(reread.approvedFingerprint(for: codex) == "abc")
  #expect(reread.isDeclined(codex))
  #expect(!reread.isDeclined(AgentProviderID("claude-code")))
}
