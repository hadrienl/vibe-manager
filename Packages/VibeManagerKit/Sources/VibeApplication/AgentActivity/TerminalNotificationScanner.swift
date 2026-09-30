import Foundation

/// Finds the notifications a program writes to its terminal as OSC 9 — `ESC ] 9 ; message BEL`,
/// or ended by `ESC \` — in its output, read after read (#273).
///
/// Codex announces this way the dialogs its hooks never report. A sequence split across two reads
/// is kept until its end comes; one that never ends is let go past `limit` bytes.
public struct TerminalNotificationScanner: Sendable {
  static let introducer: [UInt8] = [0x1B, 0x5D, 0x39, 0x3B]
  /// The longest message kept: Codex cuts what it quotes to a few dozen characters.
  public static let limit = 4096

  private var pending: [UInt8] = []

  public init() {}

  /// The messages ended in `bytes`, in the order written.
  public mutating func scan(_ bytes: [UInt8]) -> [String] {
    // Most reads hold no escape at all: they go by without a copy.
    guard !pending.isEmpty || bytes.contains(0x1B) else { return [] }
    let buffer = pending.isEmpty ? bytes : pending + bytes
    pending = []
    var messages: [String] = []
    var start = buffer.startIndex
    while let found = Self.firstIndex(of: Self.introducer, in: buffer, from: start) {
      let body = found + Self.introducer.count
      guard let end = Self.end(in: buffer, from: body) else {
        // Unfinished: kept for the next read, unless it has run on too long to be one.
        if buffer.count - body <= Self.limit { pending = Array(buffer[found...]) }
        return messages
      }
      if let bodyEnd = end.body {
        messages.append(String(decoding: buffer[body..<bodyEnd], as: UTF8.self))
      }
      start = end.next
    }
    // An escape at the very end may begin the next sequence.
    let tail = buffer.suffix(Self.introducer.count - 1)
    if let escape = tail.lastIndex(of: 0x1B), Self.introducer.starts(with: buffer[escape...]) {
      pending = Array(buffer[escape...])
    }
    return messages
  }

  static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
    guard haystack.count >= needle.count, start <= haystack.count - needle.count else {
      return nil
    }
    var index = start
    while index <= haystack.count - needle.count {
      if haystack[index] == needle[0], haystack[index..<index + needle.count].elementsEqual(needle)
      {
        return index
      }
      index += 1
    }
    return nil
  }

  /// Where the message ends — BEL, or ESC `\` — and where the output goes on after it. `body` is
  /// `nil` for a sequence cut by another escape: what it held is let go.
  static func end(in buffer: [UInt8], from start: Int) -> (body: Int?, next: Int)? {
    var index = start
    while index < buffer.count {
      switch buffer[index] {
      case 0x07:
        return (index, index + 1)
      case 0x1B:
        guard index + 1 < buffer.count else { return nil }
        if buffer[index + 1] == 0x5C { return (index, index + 2) }
        return (nil, index)
      default:
        index += 1
      }
    }
    return nil
  }
}
