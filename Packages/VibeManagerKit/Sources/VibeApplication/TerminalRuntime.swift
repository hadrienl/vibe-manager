public enum TerminalEvent: Equatable, Sendable {
  case started
  case output(String)
  case stopped(exitCode: Int32)
}

public protocol TerminalRuntime: Sendable {
  func events() -> AsyncStream<TerminalEvent>
  func stop() async
}
