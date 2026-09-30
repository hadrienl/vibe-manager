/// Watches the output of a terminal whose view is put away for what the view would have to act on
/// at once (#248): the questions a program asks its terminal — where the cursor is, what the
/// terminal is, its colours, its modes — and the folder a shell says it is in.
///
/// A hidden view is no longer fed, so nothing would answer: Codex started in the background waits
/// for the position of the cursor before it draws anything. Seeing one of these is the view's cue
/// to catch up, which answers with the exact state of the screen.
///
/// No terminal is emulated here. A few states follow the escape sequences, across reads, and only
/// complete ones count: the terminal answers when a sequence ends. The list is taken from every
/// answer SwiftTerm 1.20 sends; a false alarm costs one catch-up, a miss an answer that waits for
/// the view to come back.
public struct TerminalQuerySentinel: Sendable {
  public enum Query: String, Sendable, Equatable {
    /// `CSI n`: the cursor's position, the terminal's status.
    case statusReport
    /// `CSI c`: the terminal's attributes, primary, secondary or tertiary.
    case attributes
    /// `CSI ? u`: the keyboard protocol in force.
    case keyboard
    /// `CSI $ p`: whether a mode is set.
    case mode
    /// `CSI > q`: the terminal's name and version.
    case version
    /// `CSI * y`: a checksum of part of the screen.
    case checksum
    /// `CSI t`: the size of the window or of a cell.
    case window
    /// `OSC 4, 10, 11, 12 ; ?`: a colour.
    case colour
    /// `OSC 52 ; ?`: the clipboard.
    case clipboard
    /// `OSC 7`: the folder the shell is in, which a side terminal's title reads.
    case directory
    /// `DCS $ q` and `DCS + q`: a setting, or a capability.
    case setting
    /// `APC G`: a graphics command, which is answered.
    case graphics
  }

  private enum State: Sendable {
    case ground
    case escape
    /// `ESC` followed by an intermediate: a character set, until its final byte.
    case escapeIntermediate
    case controlSequence
    case string(StringKind)
    /// An `ESC` inside a string: `\` ends it, anything else starts another sequence.
    case stringEscape(StringKind)
  }

  private enum StringKind: Sendable {
    case operatingSystem
    case deviceControl
    case application
    /// A string nobody answers — privacy messages, start of string: skipped to its end.
    case ignored
  }

  /// Answered window reports: `CSI 11 t` and following.
  private static let windowReports: Set<Int> = [11, 13, 14, 15, 16, 18, 19, 20, 21]
  /// Enough of a string to recognise it; the rest is only looked through for `?`.
  private static let headerLimit = 16

  private var state = State.ground
  private var parameters: [UInt8] = []
  private var intermediates: [UInt8] = []
  private var header: [UInt8] = []
  private var asksSomething = false

  public init() {}

  /// Reads the next piece of output. Returns the last query a sequence completed in it, if any.
  public mutating func scan(_ bytes: some Sequence<UInt8>) -> Query? {
    var found: Query?
    for byte in bytes {
      if let query = consume(byte) { found = query }
    }
    return found
  }

  private mutating func consume(_ byte: UInt8) -> Query? {
    switch state {
    case .ground:
      if byte == 0x1B { state = .escape }
      return nil
    case .escape:
      return afterEscape(byte)
    case .escapeIntermediate:
      if byte == 0x1B {
        state = .escape
      } else if byte >= 0x30 || byte == 0x18 || byte == 0x1A {
        state = .ground
      }
      return nil
    case .controlSequence:
      return inControlSequence(byte)
    case .string(let kind):
      return inString(kind, byte)
    case .stringEscape(let kind):
      if byte == UInt8(ascii: "\\") {
        state = .ground
        return ended(kind)
      }
      // Another sequence began: the string ended unanswered.
      state = .escape
      return afterEscape(byte)
    }
  }

  private mutating func afterEscape(_ byte: UInt8) -> Query? {
    switch byte {
    case UInt8(ascii: "["):
      parameters.removeAll(keepingCapacity: true)
      intermediates.removeAll(keepingCapacity: true)
      state = .controlSequence
    case UInt8(ascii: "]"):
      beginString(.operatingSystem)
    case UInt8(ascii: "P"):
      beginString(.deviceControl)
    case UInt8(ascii: "_"):
      beginString(.application)
    case UInt8(ascii: "X"), UInt8(ascii: "^"):
      beginString(.ignored)
    case 0x1B:
      state = .escape
    case 0x20...0x2F:
      state = .escapeIntermediate
    default:
      state = .ground
    }
    return nil
  }

  private mutating func beginString(_ kind: StringKind) {
    header.removeAll(keepingCapacity: true)
    asksSomething = false
    state = .string(kind)
  }

  private mutating func inControlSequence(_ byte: UInt8) -> Query? {
    switch byte {
    case 0x30...0x3F:
      if parameters.count < Self.headerLimit { parameters.append(byte) }
      return nil
    case 0x20...0x2F:
      if intermediates.count < Self.headerLimit { intermediates.append(byte) }
      return nil
    case 0x40...0x7E:
      state = .ground
      return controlSequenceQuery(final: byte)
    case 0x1B:
      state = .escape
      return nil
    case 0x18, 0x1A:
      state = .ground
      return nil
    default:
      // A control character inside a sequence is carried out and the sequence goes on.
      return nil
    }
  }

  private func controlSequenceQuery(final: UInt8) -> Query? {
    let marker = parameters.first
    switch (final, intermediates) {
    case (UInt8(ascii: "n"), []):
      return .statusReport
    case (UInt8(ascii: "c"), []):
      return .attributes
    case (UInt8(ascii: "u"), []) where marker == UInt8(ascii: "?"):
      return .keyboard
    case (UInt8(ascii: "p"), [UInt8(ascii: "$")]):
      return .mode
    case (UInt8(ascii: "q"), []) where marker == UInt8(ascii: ">"):
      return .version
    case (UInt8(ascii: "y"), [UInt8(ascii: "*")]):
      return .checksum
    case (UInt8(ascii: "t"), []):
      let first = parameters.prefix { $0 != UInt8(ascii: ";") }
      guard let number = Int(String(decoding: first, as: UTF8.self)),
        Self.windowReports.contains(number)
      else { return nil }
      return .window
    default:
      return nil
    }
  }

  private mutating func inString(_ kind: StringKind, _ byte: UInt8) -> Query? {
    switch byte {
    case 0x1B:
      state = .stringEscape(kind)
      return nil
    case 0x07 where kind == .operatingSystem:
      // BEL ends an operating system command, as the string terminator does.
      state = .ground
      return ended(kind)
    case 0x18, 0x1A:
      state = .ground
      return nil
    default:
      if header.count < Self.headerLimit {
        header.append(byte)
      } else if byte == UInt8(ascii: "?") {
        asksSomething = true
      }
      return nil
    }
  }

  private func ended(_ kind: StringKind) -> Query? {
    switch kind {
    case .operatingSystem:
      let number = header.prefix { $0 != UInt8(ascii: ";") }
      let asks = asksSomething || header.dropFirst(number.count).contains(UInt8(ascii: "?"))
      switch String(decoding: number, as: UTF8.self) {
      case "7": return .directory
      case "4", "10", "11", "12": return asks ? .colour : nil
      case "52": return asks ? .clipboard : nil
      default: return nil
      }
    case .deviceControl:
      // Parameters, then `$ q` or `+ q`.
      let body = header.drop { (0x30...0x3F).contains($0) }
      guard body.count >= 2, body[body.startIndex + 1] == UInt8(ascii: "q"),
        [UInt8(ascii: "$"), UInt8(ascii: "+")].contains(body[body.startIndex])
      else { return nil }
      return .setting
    case .application:
      return header.first == UInt8(ascii: "G") ? .graphics : nil
    case .ignored:
      return nil
    }
  }
}
