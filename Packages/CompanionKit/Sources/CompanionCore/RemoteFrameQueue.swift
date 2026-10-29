import Foundation

/// The frames of one connection, written one after the other in the order they were asked (#452).
///
/// A write per task would leave the order to the scheduler: the `show` asked at the connection
/// could reach the Mac before the `hello`, which it ignores, and the conversation never came.
/// One at a time also means a long write — files sent with a message — holds back the frames
/// asked after it until it is written.
public final class RemoteFrameQueue: Sendable {
  private let frames: AsyncStream<Data>.Continuation
  private let writer: Task<Void, Never>

  /// `write` is called for each frame, never two at once. A failed write ends the queue: what is
  /// asked after it is dropped, and `failed` is called once, for the channel to reconnect.
  public init(
    write: @escaping @Sendable (Data) async throws -> Void,
    failed: @escaping @Sendable (any Error) async -> Void
  ) {
    let (stream, frames) = AsyncStream.makeStream(of: Data.self)
    self.frames = frames
    writer = Task {
      for await frame in stream {
        do {
          try await write(frame)
        } catch {
          frames.finish()
          if !Task.isCancelled { await failed(error) }
          return
        }
      }
    }
  }

  deinit { finish() }

  public func enqueue(_ frame: Data) { frames.yield(frame) }

  /// What is not written yet is dropped.
  public func finish() {
    frames.finish()
    writer.cancel()
  }
}
