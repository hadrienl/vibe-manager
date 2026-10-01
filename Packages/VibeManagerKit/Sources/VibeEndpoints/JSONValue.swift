import Foundation

/// Any JSON value, kept as it came.
///
/// The gateway translates between protocols it does not own: a field it has never heard of must go
/// through untouched, and a missing one must not fail a whole request. Typed `Codable` models
/// would do neither, so both sides are read and written as trees, and only the fields a
/// translation needs are looked at.
public enum JSONValue: Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public subscript(key: String) -> JSONValue? {
    guard case .object(let fields) = self else { return nil }
    return fields[key]
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var numberValue: Double? {
    guard case .number(let value) = self else { return nil }
    return value
  }

  public var intValue: Int? {
    guard case .number(let value) = self, value.isFinite else { return nil }
    return Int(exactly: value.rounded(.towardZero))
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [JSONValue]? {
    guard case .array(let values) = self else { return nil }
    return values
  }

  public var objectValue: [String: JSONValue]? {
    guard case .object(let fields) = self else { return nil }
    return fields
  }

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  // MARK: - Bytes

  public init(parsing data: Data) throws {
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    self = try JSONValue(foundation: object)
  }

  public init(parsing text: String) throws {
    try self.init(parsing: Data(text.utf8))
  }

  /// Compact and with sorted keys: the same value always gives the same bytes, which is what the
  /// golden tests compare.
  public func data() -> Data {
    var output = ""
    write(to: &output)
    return Data(output.utf8)
  }

  public func text() -> String {
    var output = ""
    write(to: &output)
    return output
  }

  private init(foundation object: Any) throws {
    switch object {
    case is NSNull:
      self = .null
    case let number as NSNumber:
      // `JSONSerialization` gives booleans as `NSNumber` too; only their type tells them apart.
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
      } else {
        self = .number(number.doubleValue)
      }
    case let string as String:
      self = .string(string)
    case let array as [Any]:
      self = .array(try array.map { try JSONValue(foundation: $0) })
    case let dictionary as [String: Any]:
      self = .object(try dictionary.mapValues { try JSONValue(foundation: $0) })
    default:
      throw JSONValueError.unsupported
    }
  }

  private func write(to output: inout String) {
    switch self {
    case .null:
      output += "null"
    case .bool(let value):
      output += value ? "true" : "false"
    case .number(let value):
      output += Self.format(value)
    case .string(let value):
      Self.escape(value, into: &output)
    case .array(let values):
      output += "["
      for (index, value) in values.enumerated() {
        if index > 0 { output += "," }
        value.write(to: &output)
      }
      output += "]"
    case .object(let fields):
      output += "{"
      for (index, key) in fields.keys.sorted().enumerated() {
        if index > 0 { output += "," }
        Self.escape(key, into: &output)
        output += ":"
        fields[key]?.write(to: &output)
      }
      output += "}"
    }
  }

  private static func format(_ value: Double) -> String {
    guard value.isFinite else { return "null" }
    if value == value.rounded(), abs(value) < 1e15 {
      return String(Int64(value))
    }
    return String(value)
  }

  private static func escape(_ string: String, into output: inout String) {
    output += "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": output += "\\\""
      case "\\": output += "\\\\"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      case let control where control.value < 0x20:
        output += String(format: "\\u%04x", control.value)
      default:
        output.unicodeScalars.append(scalar)
      }
    }
    output += "\""
  }
}

public enum JSONValueError: Error, Equatable {
  case unsupported
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
  ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
  ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
  public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let values): try container.encode(values)
    case .object(let fields): try container.encode(fields)
    }
  }
}
