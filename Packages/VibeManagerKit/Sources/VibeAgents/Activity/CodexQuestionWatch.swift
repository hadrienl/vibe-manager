import Foundation
import VibeApplication

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
///
/// `request_user_input_async` (#273) asks without waiting: its output, `accepted`, comes at once,
/// and the agent goes on. Codex keeps the question until the user answers it or the turn ends,
/// when it takes it away — so does the watch, at the turn's end the rollout writes.
public struct CodexQuestionWatch: Sendable {
  static let tool = "request_user_input"
  static let asyncTool = "request_user_input_async"
  /// What the set of pending calls holds for an asynchronous question: no output settles it.
  static let asyncMark = "async:"

  private let sessionsDirectory: URL
  private let workingDirectoryPath: String
  private let since: Date
  private let discoveryInterval: Duration
  private let discoveryTimeout: Duration

  public init(
    sessionsDirectory: URL,
    workingDirectoryPath: String,
    since: Date,
    discoveryInterval: Duration = .milliseconds(500),
    discoveryTimeout: Duration = .seconds(30)
  ) {
    self.sessionsDirectory = sessionsDirectory
    self.workingDirectoryPath = workingDirectoryPath
    // The hook writes whole seconds: the rollout may be dated a moment before.
    self.since = since.addingTimeInterval(-2)
    self.discoveryInterval = discoveryInterval
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
        let lines = AppendedLines(file: rollout, start: .offset(offset), needles: Self.needles)
          .lines()
        for await line in lines {
          guard !Task.isCancelled else { break }
          for signal in Self.signals(in: line, pending: &pending) { continuation.yield(signal) }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// The words a line must hold to matter here, looked for before any JSON is decoded.
  /// The name of either tool holds `tool`.
  static let needles = [
    Data(tool.utf8), Data("function_call_output".utf8), Data("task_complete".utf8),
    Data("turn_aborted".utf8),
  ]

  /// The questions the rollout holds that no output has answered yet, and where its last whole
  /// line ends: what follows is followed as it comes. Read by blocks, never whole.
  static func unanswered(in rollout: URL) -> (Set<String>, [AgentSignal], UInt64) {
    guard let handle = try? FileHandle(forReadingFrom: rollout) else { return ([], [], 0) }
    defer { try? handle.close() }
    var pending: Set<String> = []
    var asked: [String: AgentSignal] = [:]
    var order: [String] = []
    var splitter = LineSplitter()
    var read = 0
    while let block = try? handle.read(upToCount: AppendedLines.blockSize), !block.isEmpty {
      read += block.count
      splitter.append(block) { line in
        guard LineSplitter.contains(line, anyOf: needles) else { return }
        for signal in signals(in: line, pending: &pending) {
          guard case .questionAsked(_, _, let notice) = signal,
            let key = notice?.reference.subject
          else { continue }
          asked[key] = signal
          order.append(key)
        }
      }
    }
    let waiting = order.filter { pending.contains($0) || pending.contains(asyncMark + $0) }
      .compactMap { asked[$0] }
    return (pending, waiting, UInt64(read - splitter.pendingCount))
  }

  /// What one line of a rollout says about questions: one asked, or some of those answered.
  static func signals(in line: Data, pending: inout Set<String>) -> [AgentSignal] {
    // Most lines are messages and tool output, some large: the words are looked for first.
    let isCall = line.range(of: Data(tool.utf8)) != nil
    guard isCall || (!pending.isEmpty && LineSplitter.contains(line, anyOf: needles)),
      let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
      let payload = object["payload"] as? [String: Any]
    else { return [] }
    if object["type"] as? String == "event_msg" {
      // The turn is over: Codex takes its asynchronous questions away.
      guard ["task_complete", "turn_aborted"].contains(payload["type"] as? String) else {
        return []
      }
      let ended = pending.filter { $0.hasPrefix(asyncMark) }
      pending.subtract(ended)
      return ended.sorted().map {
        .toolFinished(asyncTool, subject: String($0.dropFirst(asyncMark.count)))
      }
    }
    guard object["type"] as? String == "response_item",
      let callID = payload["call_id"] as? String
    else { return [] }
    switch payload["type"] as? String {
    case "function_call" where [tool, asyncTool].contains(payload["name"] as? String):
      let name = payload["name"] as? String ?? tool
      let isAsync = name == asyncTool
      guard pending.insert(isAsync ? asyncMark + callID : callID).inserted else { return [] }
      let arguments = (payload["arguments"] as? String).flatMap {
        (text: String) -> [String: Any]? in
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
      }
      let questions =
        isAsync
        ? asyncQuestions(in: arguments ?? [:])
        : AgentRequestReading.questions(in: arguments ?? [:])
      let notice = AgentRequestNotice(
        content: questions.isEmpty ? .unreadable(tool: name) : .questions(questions),
        reference: AgentToolReference(tool: name, subject: callID),
        isShown: false,
        key: "codex:\(callID)",
        isAsynchronous: isAsync
      )
      return [.questionAsked(.question, tool: name, notice: notice)]
    case "function_call_output":
      // An asynchronous question's output only says it was taken.
      guard pending.remove(callID) != nil else { return [] }
      return [.toolFinished(tool, subject: callID)]
    default:
      return []
    }
  }

  /// The questions of `request_user_input_async`: a title each, and answers to suggest — plain
  /// words, the first preselected. An answer of one's own is always possible.
  static func asyncQuestions(in arguments: [String: Any]) -> [AgentQuestion] {
    (arguments["questions"] as? [[String: Any]] ?? []).compactMap { question in
      guard let title = question["title"] as? String else { return nil }
      let options = (question["options"] as? [String] ?? []).map { AgentQuestion.Option(label: $0) }
      return AgentQuestion(header: nil, text: title, options: options)
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
      try? await Task.sleep(for: discoveryInterval, tolerance: discoveryInterval / 2)
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
