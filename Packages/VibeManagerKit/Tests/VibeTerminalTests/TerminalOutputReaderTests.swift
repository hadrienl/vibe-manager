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
