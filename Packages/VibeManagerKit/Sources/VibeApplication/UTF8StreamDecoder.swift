/// Turns a stream of terminal reads into text, across the reads.
///
/// A pseudo terminal hands out whatever bytes are available, so a multi-byte character can be
/// split between two reads. Decoding each read on its own replaces both halves with U+FFFD, and
/// the character is lost for good: the byte that would have completed it has already been
/// decoded as garbage. The incomplete tail is held back until the read that finishes it.
public struct UTF8StreamDecoder: Sendable {
  private var pending: [UInt8] = []

  public init() {}

  /// The text these bytes complete. A sequence left open is kept for the next call.
  public mutating func decode(_ bytes: [UInt8]) -> String {
    var buffer = pending
    buffer.append(contentsOf: bytes)
    pending = []

    let held = Self.openSequenceLength(at: buffer)
    if held > 0 {
      pending = Array(buffer.suffix(held))
      buffer.removeLast(held)
    }
    return String(decoding: buffer, as: UTF8.self)
  }

  /// Whatever is still held when the stream ends.
  ///
  /// The sequence will never be completed now, so it is decoded as it stands — the replacement
  /// character is the honest answer at that point, and dropping the bytes silently is not.
  public mutating func flush() -> String {
    defer { pending = [] }
    return pending.isEmpty ? "" : String(decoding: pending, as: UTF8.self)
  }

  /// How many trailing bytes belong to a sequence that is started but not finished.
  private static func openSequenceLength(at bytes: [UInt8]) -> Int {
    // A sequence is four bytes at most, so only the last three can still be waiting.
    var index = bytes.count - 1
    var continuations = 0
    while index >= 0, continuations < 3 {
      let byte = bytes[index]
      if byte & 0b1100_0000 == 0b1000_0000 {
        continuations += 1
        index -= 1
        continue
      }
      let expected = sequenceLength(leadingWith: byte)
      // ASCII, or a byte that can lead nothing: there is nothing to wait for.
      guard expected > 0 else { return 0 }
      let present = continuations + 1
      return expected > present ? present : 0
    }
    return 0
  }

  private static func sequenceLength(leadingWith byte: UInt8) -> Int {
    if byte & 0b1000_0000 == 0 { return 0 }
    if byte & 0b1110_0000 == 0b1100_0000 { return 2 }
    if byte & 0b1111_0000 == 0b1110_0000 { return 3 }
    if byte & 0b1111_1000 == 0b1111_0000 { return 4 }
    return 0
  }
}
