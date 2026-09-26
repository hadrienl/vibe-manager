import Foundation
import VibeApplication

/// Follows a file an agent appends to, line by line: only whole lines, from where the reading
/// started, and from the beginning again when the file was replaced by a shorter one.
struct AppendedLines: Sendable {
  enum Start: Sendable {
    /// What the file holds already belongs to the past.
    case end
    case beginning
    /// From this offset, what was before having been read otherwise.
    case offset(UInt64)
  }

  let file: URL
  let start: Start
  let pollInterval: Duration

  func lines() -> AsyncStream<Data> {
    let file = file
    let start = start
    let pollInterval = pollInterval
    return AsyncStream { continuation in
      let task = Task {
        var offset: UInt64
        switch start {
        case .end: offset = Self.size(of: file)
        case .beginning: offset = 0
        case .offset(let value): offset = value
        }
        var pending = Data()
        while !Task.isCancelled {
          if let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            let size = Self.size(of: file)
            if size < offset {
              offset = 0
              pending = Data()
            }
            if size > offset, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(size - offset))
            {
              offset += UInt64(data.count)
              pending.append(data)
              while let newline = pending.firstIndex(of: 0x0A) {
                continuation.yield(Data(pending[pending.startIndex..<newline]))
                pending = Data(pending[(newline + 1)...])
              }
            }
          }
          try? await Task.sleep(for: pollInterval)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  static func size(of url: URL) -> UInt64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
  }
}

/// Reads the questions Codex asks with `request_user_input` from the rollout of its session (#40).
///
/// No hook reports them: Codex 0.157.1 sends `PreToolUse` for the tool, but only through a hook
/// that would have to be approved again. The rollout already says it — a `function_call` named
/// `request_user_input`, then a `function_call_output` with the same `call_id` once answered — and
/// reading it needs nobody's approval.
///
/// Both are written before the question is drawn and after it is gone: nothing says when its
/// dialog is on screen, so these questions are shown, and answered in the terminal.
///
/// The rollout is the one created for this working directory once the session started, the oldest
/// of them, as `CodexRolloutSessionDiscovery` picks. Two Codex sessions started in the same folder
/// in the same seconds could see each other's question; it would only be shown, never answered.
public struct CodexQuestionWatch: Sendable {
  static let tool = "request_user_input"

  private let sessionsDirectory: URL
  private let workingDirectoryPath: String
  private let since: Date
  private let pollInterval: Duration
  private let discoveryTimeout: Duration

  public init(
    sessionsDirectory: URL,
    workingDirectoryPath: String,
    since: Date,
    pollInterval: Duration = .milliseconds(500),
    discoveryTimeout: Duration = .seconds(30)
  ) {
    self.sessionsDirectory = sessionsDirectory
    self.workingDirectoryPath = workingDirectoryPath
    // The hook writes whole seconds: the rollout may be dated a moment before.
    self.since = since.addingTimeInterval(-2)
    self.pollInterval = pollInterval
    self.discoveryTimeout = discoveryTimeout
  }

  public func signals() -> AsyncStream<AgentSignal> {
    let watch = self
    return AsyncStream { continuation in
      let task = Task {
        guard let rollout = await watch.rollout() else {
          continuation.finish()
          return
        }
        // What the rollout holds already is the past: only the questions still unanswered in it
        // are said, once — not every question the session ever asked, answered long ago.
        let (unanswered, waiting, offset) = Self.unanswered(in: rollout)
        var pending = unanswered
        for signal in waiting { continuation.yield(signal) }
        let lines = AppendedLines(
          file: rollout, start: .offset(offset), pollInterval: watch.pollInterval
        ).lines()
        for await line in lines {
          guard !Task.isCancelled else { break }
          for signal in Self.signals(in: line, pending: &pending) { continuation.yield(signal) }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// The questions the rollout holds that no output has answered yet, and where its whole lines
  /// end: what follows is followed as it comes.
  static func unanswered(in rollout: URL) -> (Set<String>, [AgentSignal], UInt64) {
    guard let data = try? Data(contentsOf: rollout),
      let last = data.lastIndex(of: 0x0A)
    else { return ([], [], 0) }
    var pending: Set<String> = []
    var asked: [String: AgentSignal] = [:]
    var order: [String] = []
    for line in data[data.startIndex..<last].split(separator: 0x0A) {
      for signal in signals(in: Data(line), pending: &pending) {
        guard case .questionAsked(_, _, let notice) = signal,
          let key = notice?.reference.subject
        else { continue }
        asked[key] = signal
        order.append(key)
      }
    }
    let waiting = order.filter(pending.contains).compactMap { asked[$0] }
    return (pending, waiting, UInt64(last - data.startIndex + 1))
  }

  /// What one line of a rollout says about questions: one asked, or one of those answered.
  static func signals(in line: Data, pending: inout Set<String>) -> [AgentSignal] {
    // Most lines are messages and tool output, some large: the words are looked for first.
    let isCall = line.range(of: Data(tool.utf8)) != nil
    guard isCall || (!pending.isEmpty && line.range(of: Data("function_call_output".utf8)) != nil),
      let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
      object["type"] as? String == "response_item",
      let payload = object["payload"] as? [String: Any],
      let callID = payload["call_id"] as? String
    else { return [] }
    switch payload["type"] as? String {
    case "function_call" where payload["name"] as? String == tool:
      guard pending.insert(callID).inserted else { return [] }
      let arguments = (payload["arguments"] as? String).flatMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
      }
      let questions = AgentRequestReading.questions(in: arguments ?? [:])
      let notice = AgentRequestNotice(
        content: questions.isEmpty ? .unreadable(tool: tool) : .questions(questions),
        reference: AgentToolReference(tool: tool, subject: callID),
        isShown: false,
        key: "codex:\(callID)"
      )
      return [.questionAsked(.question, tool: tool, notice: notice)]
    case "function_call_output":
      guard pending.remove(callID) != nil else { return [] }
      return [.toolFinished(tool, subject: callID)]
    default:
      return []
    }
  }

  /// The rollout of the session, once Codex has created it.
  func rollout() async -> URL? {
    let deadline = ContinuousClock.now.advanced(by: discoveryTimeout)
    let workingDirectory = Self.canonicalPath(workingDirectoryPath)
    while !Task.isCancelled {
      if let found = candidates().first(where: {
        Self.workingDirectory(of: $0).map(Self.canonicalPath) == workingDirectory
      }) {
        return found
      }
      guard ContinuousClock.now < deadline else { return nil }
      try? await Task.sleep(for: pollInterval)
    }
    return nil
  }

  /// Rollouts created since the session started, oldest first, in the folders of those days.
  private func candidates() -> [URL] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    var day = calendar.startOfDay(for: since)
    let today = calendar.startOfDay(for: Date())
    var found: [(URL, Date)] = []
    while day <= today {
      let parts = calendar.dateComponents([.year, .month, .day], from: day)
      let folder =
        sessionsDirectory
        .appendingPathComponent(String(format: "%04d", parts.year ?? 0))
        .appendingPathComponent(String(format: "%02d", parts.month ?? 0))
        .appendingPathComponent(String(format: "%02d", parts.day ?? 0))
      let files =
        (try? FileManager.default.contentsOfDirectory(
          at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
      for file in files where file.pathExtension == "jsonl" {
        let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        if let created, created >= since { found.append((file, created)) }
      }
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    return found.sorted { $0.1 < $1.1 }.map(\.0)
  }

  /// The `cwd` of the rollout's first line, `session_meta`. That line carries the instructions of
  /// the session too, which are large but bounded.
  static func workingDirectory(of rollout: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: rollout) else { return nil }
    defer { try? handle.close() }
    var line = Data()
    while line.count < 4 * 1024 * 1024, let chunk = try? handle.read(upToCount: 64 * 1024),
      !chunk.isEmpty
    {
      if let newline = chunk.firstIndex(of: 0x0A) {
        line.append(chunk[chunk.startIndex..<newline])
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        return (object?["payload"] as? [String: Any])?["cwd"] as? String
      }
      line.append(chunk)
    }
    return nil
  }

  static func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
  }
}
