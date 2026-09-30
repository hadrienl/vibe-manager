import Foundation

/// Cuts bytes into lines as they arrive (#249).
///
/// A line cut by the end of what was read is carried until the bytes that end it come. Line feeds
/// are found with `memchr`, and each line is copied once: nothing is copied again as lines are
/// taken, however many there are.
struct LineSplitter {
  private var carry = Data()

  /// Bytes held that no line feed ended yet.
  var carriedCount: Int { carry.count }

  /// The lines `bytes` ends, after what was carried, without their line feed; empty lines are
  /// left out. What follows the last line feed is carried to the next call.
  mutating func lines(in bytes: Data) -> [Data] {
    var lines: [Data] = []
    bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      guard let base = buffer.baseAddress, buffer.count > 0 else { return }
      var start = 0
      while start < buffer.count,
        let found = memchr(base + start, Int32(UInt8(ascii: "\n")), buffer.count - start)
      {
        let end = base.distance(to: UnsafeRawPointer(found))
        if carry.isEmpty {
          if end > start { lines.append(Data(bytes: base + start, count: end - start)) }
        } else {
          carry.append(base.assumingMemoryBound(to: UInt8.self) + start, count: end - start)
          lines.append(carry)
          carry = Data()
        }
        start = end + 1
      }
      if start < buffer.count {
        carry.append(base.assumingMemoryBound(to: UInt8.self) + start, count: buffer.count - start)
      }
    }
    return lines
  }

  /// Forgets what was carried: the file is read again from somewhere else.
  mutating func reset() {
    carry = Data()
  }
}
