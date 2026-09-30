import Foundation

/// Cuts the bytes of a file, read in blocks, into its lines — in one pass, whatever their number.
///
/// Each block is appended, and every line it completes is handed out without its newline, as a
/// slice of `Data` that shares the block's storage: decode it and let it go, since a slice kept
/// around keeps its whole block alive. Its `startIndex` is seldom 0. Only the incomplete rest is
/// kept, copied once per block. A line longer than `maximumLineLength` without a newline is
/// dropped whole, so that a runaway line cannot grow the rest without end.
struct LineSplitter {
  static let defaultMaximumLineLength = 16 * 1024 * 1024

  let maximumLineLength: Int
  private var rest = Data()
  private var skipsToNewline = false
  /// Bytes copied to join blocks to incomplete rests, over the splitter's life: at most twice what
  /// was appended, however many lines — what a test can count instead of timing.
  private(set) var copiedBytes = 0

  init(maximumLineLength: Int = Self.defaultMaximumLineLength) {
    self.maximumLineLength = maximumLineLength
  }

  /// The incomplete line held so far, in bytes.
  var pendingCount: Int { rest.count }

  /// Appends `block` and hands out, in order, each whole line it completes.
  mutating func append(_ block: Data, _ body: (Data) throws -> Void) rethrows {
    guard !block.isEmpty else { return }
    let buffer: Data
    if rest.isEmpty {
      buffer = block
    } else {
      rest.append(block)
      copiedBytes += block.count
      buffer = rest
    }
    var lineStart = buffer.startIndex
    try buffer.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count,
        let found = memchr(base + offset, 0x0A, bytes.count - offset)
      {
        let newline = base.distance(to: UnsafeRawPointer(found))
        let line = buffer[(buffer.startIndex + offset)..<(buffer.startIndex + newline)]
        if skipsToNewline {
          skipsToNewline = false
        } else {
          try body(line)
        }
        offset = newline + 1
      }
      lineStart = buffer.startIndex + offset
    }
    let remaining = buffer.endIndex - lineStart
    if skipsToNewline || remaining > maximumLineLength {
      skipsToNewline = true
      rest = Data()
    } else if remaining == 0 {
      rest = Data()
    } else if lineStart == buffer.startIndex {
      // No line ended in this block: the rest is the buffer itself, kept without a copy, and the
      // next block is appended to it.
      rest = buffer
    } else {
      rest = Data(buffer[lineStart...])
      copiedBytes += remaining
    }
  }

  /// Forgets the incomplete line: the file was replaced or cut short.
  mutating func reset() {
    rest = Data()
    skipsToNewline = false
  }

  /// Whether `line` holds one of `needles`, searched by `memmem`, without decoding anything.
  static func contains(_ line: Data, anyOf needles: [Data]) -> Bool {
    line.withUnsafeBytes { (haystack: UnsafeRawBufferPointer) in
      guard let base = haystack.baseAddress else { return false }
      return needles.contains { needle in
        needle.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
          guard let needleBase = bytes.baseAddress else { return true }
          return memmem(base, haystack.count, needleBase, bytes.count) != nil
        }
      }
    }
  }
}
