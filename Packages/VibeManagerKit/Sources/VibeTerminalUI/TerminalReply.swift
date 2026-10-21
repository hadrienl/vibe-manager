/// What the terminal itself sends the process: its answers to the program's queries, and the
/// focus reports the program asked for (#411).
///
/// They travel the way keystrokes do, yet the user typed none of them. Claude Code asks for the
/// terminal's version and attributes as soon as a command is typed at its prompt, and reports
/// focus: taken for the user's keys, they stopped the application from submitting what it typed.
enum TerminalReply {
  private static let escape: UInt8 = 0x1B

  /// Whether every byte is one of those answers — never a key: `ESC [ A`, an arrow, is not one.
  static func isReply(_ bytes: [UInt8]) -> Bool {
    var index = 0
    while index < bytes.count {
      guard let end = replyEnd(in: bytes, from: index) else { return false }
      index = end
    }
    return !bytes.isEmpty
  }

  /// Where the answer that starts at `start` ends, or `nil` if what starts there is not one.
  private static func replyEnd(in bytes: [UInt8], from start: Int) -> Int? {
    guard bytes[start] == escape, start + 1 < bytes.count else { return nil }
    switch bytes[start + 1] {
    case UInt8(ascii: "["): return controlSequenceEnd(in: bytes, from: start + 2)
    // A device control string (XTVERSION, XTGETTCAP) or an operating system command (colours).
    case UInt8(ascii: "P"), UInt8(ascii: "]"): return stringEnd(in: bytes, from: start + 2)
    default: return nil
    }
  }

  private static func controlSequenceEnd(in bytes: [UInt8], from start: Int) -> Int? {
    var index = start
    while index < bytes.count, (0x30...0x3F).contains(bytes[index]) { index += 1 }
    let parameters = bytes[start..<index]
    let intermediatesStart = index
    while index < bytes.count, (0x20...0x2F).contains(bytes[index]) { index += 1 }
    let intermediates = bytes[intermediatesStart..<index]
    guard index < bytes.count else { return nil }
    let final = bytes[index]
    let isReply: Bool =
      switch final {
      // Focus in and out.
      case UInt8(ascii: "I"), UInt8(ascii: "O"): parameters.isEmpty && intermediates.isEmpty
      // Primary and secondary device attributes.
      case UInt8(ascii: "c"):
        [UInt8(ascii: "?"), UInt8(ascii: ">")].contains(parameters.first) && intermediates.isEmpty
      // A mode's state (DECRPM).
      case UInt8(ascii: "y"): Array(intermediates) == [UInt8(ascii: "$")]
      // The keyboard protocol's flags.
      case UInt8(ascii: "u"): parameters.first == UInt8(ascii: "?") && intermediates.isEmpty
      default: false
      }
    return isReply ? index + 1 : nil
  }

  /// A string ends with BEL or with ESC `\`.
  private static func stringEnd(in bytes: [UInt8], from start: Int) -> Int? {
    var index = start
    while index < bytes.count {
      if bytes[index] == 0x07 { return index + 1 }
      if bytes[index] == escape, index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "\\") {
        return index + 2
      }
      index += 1
    }
    return nil
  }
}
