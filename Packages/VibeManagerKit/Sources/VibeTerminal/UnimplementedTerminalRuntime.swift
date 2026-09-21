import VibeApplication

public struct UnimplementedTerminalRuntime: TerminalRuntime {
  public init() {}

  public func events() -> AsyncStream<TerminalEvent> {
    AsyncStream { continuation in
      continuation.finish()
    }
  }

  public func stop() async {}
}
