import CryptoKit
import Foundation
import VibeDomain

/// Which of the two programs wrote an event.
public enum DiagnosticOrigin: String, Codable, Sendable {
  case app
  case host
}

public enum DiagnosticCategory: String, Codable, Sendable, CaseIterable {
  case lifecycle
  case session
  case host
  case agentProbe
  case git
  case store
  case notes
  case perf
}

public enum DiagnosticLevel: Int, Codable, Sendable, Comparable {
  case debug
  case info
  case notice
  case error
  case fault

  public var name: String {
    switch self {
    case .debug: return "debug"
    case .info: return "info"
    case .notice: return "notice"
    case .error: return "error"
    case .fault: return "fault"
    }
  }

  public static func < (lhs: DiagnosticLevel, rhs: DiagnosticLevel) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// One thing worth noting, and nothing that could identify what the user works on.
///
/// Safe by construction rather than by care (ADR 0020): the name is a `StaticString`, every field
/// name is one too, and every value is a `DiagnosticValue`, which has no case for free text. A
/// prompt, a session name, a note or a folder cannot be logged by accident: it does not compile.
public struct DiagnosticEvent: Sendable {
  public let at: Date
  public let category: DiagnosticCategory
  public let level: DiagnosticLevel
  public let name: StaticString
  public let fields: [(name: StaticString, value: DiagnosticValue)]

  public init(
    at: Date = Date(),
    _ category: DiagnosticCategory,
    _ level: DiagnosticLevel,
    _ name: StaticString,
    _ fields: KeyValuePairs<StaticString, DiagnosticValue> = [:]
  ) {
    self.init(at: at, category, level, name, fields: fields.map { ($0.key, $0.value) })
  }

  /// An event whose fields are computed at run time, still from the closed set of names and values.
  public init(
    at: Date = Date(),
    _ category: DiagnosticCategory,
    _ level: DiagnosticLevel,
    _ name: StaticString,
    fields: [(name: StaticString, value: DiagnosticValue)]
  ) {
    self.at = at
    self.category = category
    self.level = level
    self.name = name
    self.fields = fields
  }

  public var nameText: String { name.description }

  /// The value of a field, for tests and for the export.
  public func value(of field: String) -> DiagnosticValue? {
    fields.first { $0.name.description == field }?.value
  }
}

/// What a field may hold. There is no case for a `String`.
public enum DiagnosticValue: Hashable, Sendable {
  case count(Int)
  case bytes(Int)
  case duration(Duration)
  case flag(Bool)
  /// `errno`, an `OSStatus`, an exit status, a signal.
  case code(Int32)
  /// A value of a declared enumeration: a state, a verdict, a provider.
  case token(DiagnosticToken)
  case session(SessionPseudonym)
  case path(RedactedPath)
  case version(DiagnosticVersion)

  /// The value as it is written in a log line.
  public var jsonValue: Any {
    switch self {
    case .count(let value), .bytes(let value): return value
    case .duration(let value):
      let milliseconds =
        Double(value.components.seconds) * 1000
        + Double(value.components.attoseconds) / 1e15
      return (milliseconds * 10).rounded() / 10
    case .flag(let value): return value
    case .code(let value): return Int(value)
    case .token(let value): return value.rawValue
    case .session(let value): return value.rawValue
    case .path(let value): return value.rawValue
    case .version(let value): return value.rawValue
    }
  }
}

/// A word from a closed vocabulary: a literal in the source, or the raw value of an enumeration
/// that declares itself `DiagnosticTokenConvertible`.
public struct DiagnosticToken: Hashable, Sendable, ExpressibleByStringLiteral {
  public let rawValue: String

  public init(_ literal: StaticString) {
    rawValue = literal.description
  }

  /// A literal of the source, and only one: `StaticString` cannot be built from a variable.
  public init(stringLiteral literal: StaticString) {
    rawValue = literal.description
  }

  public init<Value: RawRepresentable & DiagnosticTokenConvertible>(_ value: Value)
  where Value.RawValue == String {
    rawValue = value.rawValue
  }
}

/// A type whose values can be logged as they are. Declared on enumerations only, whose raw values
/// are literals of the source; never on a type built from what the user typed.
public protocol DiagnosticTokenConvertible {
  var diagnosticToken: DiagnosticToken { get }
}

extension DiagnosticTokenConvertible where Self: RawRepresentable, RawValue == String {
  public var diagnosticToken: DiagnosticToken { DiagnosticToken(self) }
}

/// A version as a tool printed it, kept only if it looks like one.
public struct DiagnosticVersion: Hashable, Sendable {
  public let rawValue: String

  /// `nil` for anything but 1 to 32 characters of `[0-9A-Za-z.+-]`: a CLI that prints a path or
  /// a sentence where its version should be is not logged.
  public init?(_ text: String) {
    let allowed = CharacterSet(charactersIn: "0123456789.+-")
      .union(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    guard (1...32).contains(text.unicodeScalars.count),
      text.unicodeScalars.allSatisfy(allowed.contains)
    else { return nil }
    rawValue = text
  }
}

/// A session, recognisable from one line of the log to the next but not traceable to the store:
/// the first 8 hexadecimal characters of an HMAC of its identifier, keyed by a salt that never
/// leaves the Mac.
public struct SessionPseudonym: Hashable, Sendable {
  public let rawValue: String

  public init(_ id: SessionID, salt: Data) {
    let code = HMAC<SHA256>.authenticationCode(
      for: Data(id.rawValue.uuidString.utf8), using: SymmetricKey(data: salt))
    rawValue = "s-" + code.prefix(4).map { String(format: "%02x", $0) }.joined()
  }
}

/// A path that says where a thing is without saying what it is called.
///
/// The home folder becomes `~`, and every component under it is replaced by the first four
/// hexadecimal characters of its SHA-256: the same folder reads the same twice, and its name
/// cannot be read. The folders a binary is installed in keep their names, because a binary not
/// found is diagnosed by where it was looked for.
public struct RedactedPath: Hashable, Sendable {
  public let rawValue: String

  /// Kept as they are: where tools are installed, never where anybody's work is.
  static let clearPrefixes = [
    "/usr/bin", "/usr/local/bin", "/usr/local/Cellar", "/opt/homebrew/bin",
    "/opt/homebrew/Cellar", "/bin", "/sbin", "/usr/sbin", "/Applications/Xcode.app",
    "/Library/Developer/CommandLineTools", "/System",
  ]

  /// Directories under the home folder whose names say nothing about the user.
  static let clearHomeComponents: Set<String> = [
    ".local", "bin", ".npm-global", ".bun", ".volta", ".nvm", ".asdf", ".cargo", ".claude",
    ".codex", "local", "Library", "Logs", "Application Support", "DiagnosticReports",
  ]

  public init(_ path: String, home: String = NSHomeDirectory()) {
    let standardized = (path as NSString).standardizingPath
    if Self.clearPrefixes.contains(where: {
      standardized == $0 || standardized.hasPrefix($0 + "/")
    }) {
      rawValue = standardized
      return
    }
    let homePath = (home as NSString).standardizingPath
    if !homePath.isEmpty, homePath != "/",
      standardized == homePath || standardized.hasPrefix(homePath + "/")
    {
      let rest = standardized.dropFirst(homePath.count).split(separator: "/").map(String.init)
      let components = rest.map { Self.clearHomeComponents.contains($0) ? $0 : Self.hashed($0) }
      rawValue = (["~"] + components).joined(separator: "/")
      return
    }
    let components = standardized.split(separator: "/").map { Self.hashed(String($0)) }
    rawValue = "/" + components.joined(separator: "/")
  }

  static func hashed(_ component: String) -> String {
    let digest = SHA256.hash(data: Data(component.utf8))
    return "…" + digest.prefix(2).map { String(format: "%02x", $0) }.joined()
  }
}
