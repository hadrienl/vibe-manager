import Darwin
import Foundation
import Testing

@testable import VibeTerminal

@Test("Finishing hands over what the descriptor still holds before the stream ends")
func finishingDrainsTheDescriptor() async throws {
  var descriptors: [Int32] = [0, 0]
  #expect(pipe(&descriptors) == 0)
  let (readEnd, writeEnd) = (descriptors[0], descriptors[1])
  _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL, 0) | O_NONBLOCK)
  defer { close(writeEnd) }

  // Written and finished at once: the read source has most likely not run yet, as on a machine
  // too busy to have read the last lines of a process that just exited.
  let reader = TerminalOutputReader(descriptor: readEnd)
  let tail = Array("the last line\n".utf8)
  #expect(tail.withUnsafeBytes { write(writeEnd, $0.baseAddress, $0.count) } == tail.count)
  reader.finish()

  var received: [UInt8] = []
  for await event in reader.events {
    if case .bytes(let bytes) = event { received.append(contentsOf: bytes) }
  }
  #expect(received == tail)
}

@Test("A small chunk read after a large burst does not keep the burst's buffer")
func smallChunksDoNotInheritBurstCapacity() async throws {
  var descriptors: [Int32] = [0, 0]
  #expect(pipe(&descriptors) == 0)
  let (readEnd, writeEnd) = (descriptors[0], descriptors[1])
  _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL, 0) | O_NONBLOCK)

  let reader = TerminalOutputReader(descriptor: readEnd)
  let burst = [UInt8](repeating: UInt8(ascii: "x"), count: 48 * 1_024)
  let tail = Array("spinner\r".utf8)
  #expect(burst.withUnsafeBytes { write(writeEnd, $0.baseAddress, $0.count) } == burst.count)

  var received = 0
  var tailCapacity: Int?
  for await event in reader.events {
    guard case .bytes(let bytes) = event else { continue }
    reader.didConsume(byteCount: bytes.count)
    received += bytes.count
    if received == burst.count {
      // Waits for the burst to be handed over, so the tail comes out as a chunk of its own.
      #expect(tail.withUnsafeBytes { write(writeEnd, $0.baseAddress, $0.count) } == tail.count)
    } else if received == burst.count + tail.count {
      tailCapacity = bytes.capacity
      close(writeEnd)
    }
  }

  let capacity = try #require(tailCapacity)
  #expect(capacity < 1_024)
}
