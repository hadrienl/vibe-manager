import Darwin
import Foundation
import VibeTerminal

/// The program an agent starts as its `vibe-browser` tool server, and the `vibe` command: the
/// application's own binary, given `--browser-bridge` or `--browser-cli` (#69).
///
/// Neither creates an `NSApplication`: they are pipes to the application's socket, and die with
/// their input. The bridge outlives the application — it is the agent's child — so when the
/// application is not there it answers for itself: its tools are listed, and calling one says the
/// application is closed. It connects again at the next call, which is how the tools come back
/// after a relaunch, the agent having run on in the terminal host (ADR 0017).
public enum BrowserBridge {
  public static let bridgeFlag = "--browser-bridge"
  public static let commandLineFlag = "--browser-cli"
  /// Named in a session's terminal, for the `vibe` command.
  public static let socketEnvironmentKey = "VIBE_BROWSER_SOCKET"

  static let closedMessage =
    "Vibe Manager is not open: the web view is only there while the application is. "
    + "Ask the user to open Vibe Manager, then try again."

  /// Runs the bridge or the command if the arguments ask for one, and never returns then.
  public static func runIfRequested(
    arguments: [String] = CommandLine.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    guard arguments.count >= 2 else { return }
    switch arguments[1] {
    case bridgeFlag:
      guard arguments.count >= 3 else { exit(64) }
      signal(SIGPIPE, SIG_IGN)
      BridgeProcess(socketPath: arguments[2], verifier: CodeSigningPeerVerifier()).run()
      exit(0)
    case commandLineFlag:
      signal(SIGPIPE, SIG_IGN)
      let status = BrowserCommandLine.run(
        Array(arguments.dropFirst(2)), environment: environment,
        verifier: CodeSigningPeerVerifier())
      exit(status)
    default:
      return
    }
  }

  /// The bridge, with a verifier of the caller's choosing: the tests' fixture accepts any process
  /// of the same user, as the application's binary and the test binary are signed differently.
  public static func runBridge(socketPath: String, verifier: any TerminalHostPeerVerifier) {
    BridgeProcess(socketPath: socketPath, verifier: verifier).run()
  }

  /// Connects to the application and says hello. `nil` when it is not there, or not itself.
  static func connect(to socketPath: String, verifier: any TerminalHostPeerVerifier) -> (
    descriptor: Int32, reader: LineReader
  )? {
    guard let descriptor = UnixSocket.connect(to: socketPath) else { return nil }
    var noSignal: Int32 = 1
    setsockopt(
      descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    guard verifier.accepts(peerOf: descriptor),
      writeAll(BrowserChannelHandshake.hello(), to: descriptor)
    else {
      close(descriptor)
      return nil
    }
    let reader = LineReader(descriptor: descriptor)
    guard let answer = reader.next(),
      let value = try? JSONDecoder().decode(JSONValue.self, from: answer)
    else {
      close(descriptor)
      return nil
    }
    guard value["vibe"]?.stringValue == "welcome" else {
      if let reason = value["reason"]?.stringValue {
        FileHandle.standardError.write(Data(("vibe: " + reason + "\n").utf8))
      }
      close(descriptor)
      return nil
    }
    return (descriptor, reader)
  }
}

/// The bridge itself: standard input to the socket, the socket to standard output.
final class BridgeProcess: @unchecked Sendable {
  private let socketPath: String
  private let verifier: any TerminalHostPeerVerifier
  private let lock = NSLock()
  private var descriptor: Int32 = -1
  /// Requests sent to the application and not answered yet: answered here if it goes away.
  private var pending: [JSONValue] = []

  init(socketPath: String, verifier: any TerminalHostPeerVerifier) {
    self.socketPath = socketPath
    self.verifier = verifier
  }

  func run() {
    let input = LineReader(descriptor: STDIN_FILENO)
    while let line = input.next() {
      guard !line.isEmpty else { continue }
      handle(line)
    }
    lock.withLock {
      if descriptor >= 0 { close(descriptor) }
    }
  }

  private func handle(_ line: Data) {
    let message = try? JSONDecoder().decode(JSONValue.self, from: line)
    let id = message?["id"]
    let method = message?["method"]?.stringValue
    if connection() >= 0 {
      if let id, method != nil { lock.withLock { pending.append(id) } }
      let sent = lock.withLock { descriptor >= 0 && writeAll(line + Data([0x0A]), to: descriptor) }
      if sent { return }
      disconnected()
    }
    answerAlone(id: id, method: method, parameters: message?["params"])
  }

  /// The descriptor, connecting first if there is none.
  private func connection() -> Int32 {
    if let current = lock.withLock({ descriptor >= 0 ? descriptor : nil }) { return current }
    guard let (connected, reader) = BrowserBridge.connect(to: socketPath, verifier: verifier) else {
      return -1
    }
    lock.withLock { descriptor = connected }
    Thread.detachNewThread { [self] in
      while let answer = reader.next() {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: answer),
          let id = value["id"]
        {
          lock.withLock { pending.removeAll { $0 == id } }
        }
        emit(answer)
      }
      disconnected()
    }
    return connected
  }

  /// The application went away: what it had not answered is answered here.
  private func disconnected() {
    let unanswered: [JSONValue] = lock.withLock {
      if descriptor >= 0 { close(descriptor) }
      descriptor = -1
      defer { pending = [] }
      return pending
    }
    for id in unanswered {
      emit(Self.closedResult(id: id))
    }
  }

  private func answerAlone(id: JSONValue?, method: String?, parameters: JSONValue?) {
    guard let id, let method else { return }
    switch method {
    case "initialize":
      let requested = parameters?["protocolVersion"]?.stringValue
      let version =
        requested.flatMap { BrowserMCPServer.supportedProtocolVersions.contains($0) ? $0 : nil }
        ?? BrowserMCPServer.supportedProtocolVersions[0]
      emit(
        BrowserMCPServer.encode(result: BrowserMCPServer.initializeResult(version: version), id: id)
      )
    case "ping":
      emit(BrowserMCPServer.encode(result: [:], id: id))
    case "tools/list":
      emit(BrowserMCPServer.encode(result: BrowserToolCatalog.listResult, id: id))
    case "tools/call":
      emit(Self.closedResult(id: id))
    default:
      emit(BrowserMCPServer.encode(error: -32601, message: "Method not found: \(method)", id: id))
    }
  }

  static func closedResult(id: JSONValue) -> Data {
    BrowserMCPServer.encode(
      result: BrowserToolResult.error(BrowserBridge.closedMessage).json, id: id)
  }

  private func emit(_ line: Data) {
    var data = line
    if data.last != 0x0A { data.append(0x0A) }
    // Written with `write(2)`: `FileHandle` raises an exception on a closed pipe, and the agent
    // going away is not a crash.
    _ = lock.withLock { writeAll(data, to: STDOUT_FILENO) }
  }
}

/// `vibe browser …`, typed in a session's terminal: the same tools as the agent's, one at a time.
public enum BrowserCommandLine {
  static let usage = """
    usage: vibe browser open <url> [--background]
           vibe browser list
           vibe browser reload [<tab>]
           vibe browser read [<tab>] [--text]
           vibe browser screenshot [<tab>] -o <file.png>
           vibe browser close <tab>

    Drives the web view of the Vibe Manager session this terminal belongs to.

    """

  /// The exit status: 0 done, 2 the application is not open, 3 not in a session's terminal,
  /// 4 the user refused, 64 misuse, 1 anything else.
  public static func run(
    _ arguments: [String], environment: [String: String],
    verifier: any TerminalHostPeerVerifier
  ) -> Int32 {
    guard arguments.first == "browser", arguments.count >= 2 else {
      FileHandle.standardError.write(Data(usage.utf8))
      return arguments.first == "help" || arguments.first == "--help" ? 0 : 64
    }
    let verb = arguments[1]
    var rest = Array(arguments.dropFirst(2))
    var output: String?
    if let index = rest.firstIndex(of: "-o"), index + 1 < rest.count {
      output = rest[index + 1]
      rest.removeSubrange(index...(index + 1))
    }
    let flags = Set(rest.filter { $0.hasPrefix("--") })
    let positional = rest.filter { !$0.hasPrefix("--") }
    var call: (tool: String, arguments: [String: JSONValue])
    switch verb {
    case "open":
      guard let url = positional.first else { return misuse() }
      call = (
        "tab_open", ["url": .string(url), "activate": .bool(!flags.contains("--background"))]
      )
    case "list":
      call = ("tabs_list", [:])
    case "reload":
      call = ("tab_reload", [:])
    case "read":
      call = ("page_read", ["mode": flags.contains("--text") ? "text" : "snapshot"])
    case "screenshot":
      guard output != nil else { return misuse() }
      call = ("page_screenshot", [:])
    case "close":
      guard positional.first != nil else { return misuse() }
      call = ("tab_close", [:])
    default:
      return misuse()
    }
    if verb != "open", let tab = positional.first { call.arguments["tab"] = .string(tab) }

    guard let socketPath = environment[BrowserBridge.socketEnvironmentKey], !socketPath.isEmpty
    else {
      FileHandle.standardError.write(
        Data("vibe: run this in the terminal of a Vibe Manager session.\n".utf8))
      return 3
    }
    guard FileManager.default.fileExists(atPath: socketPath) else {
      FileHandle.standardError.write(Data(("vibe: " + BrowserBridge.closedMessage + "\n").utf8))
      return 2
    }
    guard let (descriptor, reader) = BrowserBridge.connect(to: socketPath, verifier: verifier)
    else { return 3 }
    defer { close(descriptor) }
    let request: JSONValue = [
      "jsonrpc": "2.0", "id": 1, "method": "tools/call",
      "params": ["name": .string(call.tool), "arguments": .object(call.arguments)],
    ]
    guard writeAll(BrowserMCPServer.line(request), to: descriptor), let line = reader.next(),
      let answer = try? JSONDecoder().decode(JSONValue.self, from: line)
    else {
      FileHandle.standardError.write(Data("vibe: Vibe Manager did not answer.\n".utf8))
      return 1
    }
    if let error = answer["error"]?["message"]?.stringValue {
      FileHandle.standardError.write(Data("vibe: \(error)\n".utf8))
      return 1
    }
    let result = answer["result"]
    let isError = result?["isError"]?.boolValue ?? false
    guard case .array(let content) = result?["content"] ?? .array([]) else { return 1 }
    for item in content {
      if let text = item["text"]?.stringValue {
        let handle = isError ? FileHandle.standardError : FileHandle.standardOutput
        handle.write(Data(((isError ? "vibe: " : "") + text + "\n").utf8))
      } else if let encoded = item["data"]?.stringValue, let data = Data(base64Encoded: encoded),
        let output
      {
        do {
          try data.write(to: URL(fileURLWithPath: output))
          FileHandle.standardOutput.write(Data("\(output)\n".utf8))
        } catch {
          FileHandle.standardError.write(Data("vibe: \(error.localizedDescription)\n".utf8))
          return 1
        }
      }
    }
    if isError {
      let text = content.compactMap { $0["text"]?.stringValue }.joined()
      if text.hasPrefix("The user refused") || text.hasPrefix("Nobody answered") { return 4 }
      return text == BrowserBridge.closedMessage ? 2 : 1
    }
    return 0
  }

  private static func misuse() -> Int32 {
    FileHandle.standardError.write(Data(usage.utf8))
    return 64
  }
}
