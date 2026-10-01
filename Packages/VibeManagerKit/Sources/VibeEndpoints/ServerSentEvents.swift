import Foundation

/// One Server-Sent Event: an optional `event:` name and its `data:` lines joined.
public struct ServerSentEvent: Hashable, Sendable {
  public var name: String?
  public var data: String

  public init(name: String? = nil, data: String) {
    self.name = name
    self.data = data
  }

  /// The event as it goes on the wire, blank line included.
  public var encoded: Data {
    var text = ""
    if let name { text += "event: \(name)\n" }
    for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
      text += "data: \(line)\n"
    }
    text += "\n"
    return Data(text.utf8)
  }
}

/// Reads a stream of Server-Sent Events from bytes that arrive in any chunking.
///
/// Follows the WHATWG rules the endpoints actually rely on: lines end with LF, CRLF or CR; a blank
/// line ends an event; `data:` lines are joined with LF; a comment line starts with `:`; one space
/// after the colon is dropped. `id:` and `retry:` are read and ignored: no endpoint of the agent
/// loop resumes a stream by identifier.
///
/// Some endpoints do not end with a blank line, or send lines that are not SSE at all (a JSON
/// object after `data: [DONE]`, an error body with the wrong content type). What is left when the
/// bytes end is handed back by `finish()` rather than lost.
public struct ServerSentEventParser: Sendable {
  private var buffer: [UInt8] = []
  private var name: String?
  private var dataLines: [String] = []
  private var sawCarriageReturn = false
  /// Lines outside any `field: value` syntax, kept for the caller.
  public private(set) var strayLines: [String] = []

  public init() {}

  public mutating func consume(_ bytes: some Sequence<UInt8>) -> [ServerSentEvent] {
    var events: [ServerSentEvent] = []
    for byte in bytes {
      if sawCarriageReturn {
        sawCarriageReturn = false
        if byte == UInt8(ascii: "\n") { continue }
      }
      switch byte {
      case UInt8(ascii: "\n"):
        if let event = endLine() { events.append(event) }
      case UInt8(ascii: "\r"):
        sawCarriageReturn = true
        if let event = endLine() { events.append(event) }
      default:
        buffer.append(byte)
      }
    }
    return events
  }

  /// The event still open when the stream ends, if it has data.
  public mutating func finish() -> ServerSentEvent? {
    if !buffer.isEmpty { _ = endLine() }
    return dispatch()
  }

  private mutating func endLine() -> ServerSentEvent? {
    let line = String(decoding: buffer, as: UTF8.self)
    buffer.removeAll(keepingCapacity: true)
    if line.isEmpty { return dispatch() }
    if line.hasPrefix(":") { return nil }
    let field: Substring
    var value: Substring
    if let colon = line.firstIndex(of: ":") {
      field = line[..<colon]
      value = line[line.index(after: colon)...]
      if value.hasPrefix(" ") { value = value.dropFirst() }
    } else {
      field = Substring(line)
      value = ""
    }
    switch field {
    case "data": dataLines.append(String(value))
    case "event": name = String(value)
    case "id", "retry": break
    default: strayLines.append(line)
    }
    return nil
  }

  private mutating func dispatch() -> ServerSentEvent? {
    defer {
      name = nil
      dataLines = []
    }
    guard !dataLines.isEmpty else { return nil }
    return ServerSentEvent(name: name, data: dataLines.joined(separator: "\n"))
  }
}
