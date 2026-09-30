import Foundation

/// Why an endpoint did not answer, in terms a harness and a user can act on.
///
/// The message is written for the user and never contains a secret: bodies of error responses are
/// read for their `message` field only, and cut short.
public struct EndpointFailure: Error, Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable {
    case authentication
    case permission
    case notFound
    case rateLimited
    case invalidRequest
    /// The conversation no longer fits the model: the harness compacts rather than retries.
    case contextTooLong
    case overloaded
    case server
    case network
    case timeout
    case malformedResponse
  }

  public var kind: Kind
  public var message: String
  /// The HTTP status the endpoint answered, when it did.
  public var status: Int?
  /// How long the endpoint asked to wait, from `Retry-After`.
  public var retryAfter: Duration?

  public init(kind: Kind, message: String, status: Int? = nil, retryAfter: Duration? = nil) {
    self.kind = kind
    self.message = message
    self.status = status
    self.retryAfter = retryAfter
  }

  /// The same failure with `secret` masked in its message: some endpoints quote the key they
  /// refused, and the message reaches the session's transcript.
  public func redacting(_ secret: String?) -> EndpointFailure {
    guard let secret, secret.count >= 4, message.contains(secret) else { return self }
    var copy = self
    copy.message = message.replacingOccurrences(of: secret, with: "••••")
    return copy
  }

  /// Worth another attempt before anything reached the harness.
  public var isRetryable: Bool {
    switch kind {
    case .rateLimited, .overloaded, .server, .network, .timeout, .malformedResponse: return true
    case .authentication, .permission, .notFound, .invalidRequest, .contextTooLong: return false
    }
  }

  /// Classifies an HTTP error answer from its status and body.
  public static func http(status: Int, body: Data, retryAfter: String?) -> EndpointFailure {
    let detail = Self.detail(from: body)
    let kind: Kind
    switch status {
    case 401: kind = .authentication
    case 403: kind = .permission
    case 404: kind = .notFound
    case 408: kind = .timeout
    case 413: kind = .contextTooLong
    case 429: kind = .rateLimited
    case 400, 422:
      kind = Self.looksLikeContextOverflow(detail) ? .contextTooLong : .invalidRequest
    case 529: kind = .overloaded
    case 500...599: kind = status == 503 ? .overloaded : .server
    default: kind = .invalidRequest
    }
    return EndpointFailure(
      kind: kind, message: detail.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(detail)",
      status: status, retryAfter: retryAfter.flatMap(Self.parseRetryAfter))
  }

  /// The `message` an error body carries, in any of the shapes endpoints use, cut to one line.
  static func detail(from body: Data) -> String {
    guard !body.isEmpty else { return "" }
    var text: String?
    if let json = try? JSONValue(parsing: body) {
      text =
        json["error"]?["message"]?.stringValue ?? json["error"]?.stringValue
        ?? json["message"]?.stringValue ?? json["detail"]?.stringValue
        ?? json["error"]?["error"]?.stringValue
    }
    let line = (text ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return line.count > 300 ? String(line.prefix(300)) + "…" : line
  }

  static func looksLikeContextOverflow(_ detail: String) -> Bool {
    let lowered = detail.lowercased()
    return [
      "context length", "context window", "maximum context", "too many tokens",
      "prompt is too long", "context_length_exceeded", "reduce the length",
    ]
    .contains { lowered.contains($0) }
  }

  static func parseRetryAfter(_ value: String) -> Duration? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if let seconds = Double(trimmed), seconds >= 0 { return .milliseconds(Int(seconds * 1_000)) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: trimmed) else { return nil }
    return .milliseconds(max(0, Int(date.timeIntervalSinceNow * 1_000)))
  }
}

/// A request or an answer that does not follow its protocol.
public enum EndpointProtocolError: Error, Hashable, Sendable {
  case missingField(String)
  case invalidField(String)
  case invalidJSON
}
