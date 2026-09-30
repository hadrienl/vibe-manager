import Foundation

/// The protocol an endpoint speaks.
public enum EndpointWireProtocol: String, Hashable, Codable, Sendable, CaseIterable {
  case chatCompletions
  case responses
  case messages
  /// Described by a `CustomProtocolDocument`.
  case custom
}

/// How the gateway proves who it is to an endpoint. The secret itself is never part of the
/// configuration: it lives in the keychain and reaches the gateway on its own.
public enum EndpointAuthentication: Hashable, Codable, Sendable {
  case none
  /// `Authorization: Bearer <secret>`.
  case bearer
  /// `<name>: <secret>`, such as `x-api-key`.
  case header(name: String)
  /// `?<name>=<secret>` on every URL.
  case query(name: String)
}

/// Everything the gateway needs to reach an endpoint, except its secret.
public struct EndpointConfiguration: Hashable, Sendable {
  public var baseURL: URL
  public var wireProtocol: EndpointWireProtocol
  public var authentication: EndpointAuthentication
  /// Sent with every request, after the gateway's own headers.
  public var headers: [String: String]
  /// Merged into every request body, the request's own fields winning. For what an endpoint needs
  /// and the harness does not know: a provider routing preference, a context size for a local
  /// server. A `null` value takes the field out of the request instead.
  public var defaultParameters: [String: JSONValue]
  public var timeouts: EndpointTimeouts
  /// For `wireProtocol == .custom`.
  public var customProtocol: CustomProtocolDocument?

  public init(
    baseURL: URL,
    wireProtocol: EndpointWireProtocol,
    authentication: EndpointAuthentication = .bearer,
    headers: [String: String] = [:],
    defaultParameters: [String: JSONValue] = [:],
    timeouts: EndpointTimeouts = .standard,
    customProtocol: CustomProtocolDocument? = nil
  ) {
    self.customProtocol = customProtocol
    self.baseURL = baseURL
    self.wireProtocol = wireProtocol
    self.authentication = authentication
    self.headers = headers
    self.defaultParameters = defaultParameters
    self.timeouts = timeouts
  }

  /// The URL of an operation: `chat/completions` under `https://host/api/v1` is
  /// `https://host/api/v1/chat/completions`. A base URL given with a trailing slash, or already
  /// ending with the operation, is accepted as users paste them.
  public func url(for operation: String, secret: String?) -> URL {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      return baseURL
    }
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    if !path.hasSuffix("/" + operation) { path += "/" + operation }
    components.path = path
    if case .query(let name) = authentication, let secret {
      var items = components.queryItems ?? []
      items.append(URLQueryItem(name: name, value: secret))
      components.queryItems = items
    }
    return components.url ?? baseURL
  }

  /// The Messages operation under this base: Anthropic's documentation gives the host alone, others
  /// give a base that already ends with `/v1`.
  public var messagesOperation: String {
    var path = baseURL.path
    while path.hasSuffix("/") { path.removeLast() }
    return path.hasSuffix("/v1") ? "messages" : "v1/messages"
  }

  /// The headers of every request: authentication, then the endpoint's own.
  public func requestHeaders(secret: String?) -> [String: String] {
    var headers: [String: String] = [:]
    switch authentication {
    case .bearer:
      if let secret { headers["Authorization"] = "Bearer \(secret)" }
    case .header(let name):
      if let secret { headers[name] = secret }
    case .none, .query:
      break
    }
    for (name, value) in self.headers { headers[name] = value }
    return headers
  }
}

/// Which harness sent a request, and so which protocol the gateway must answer in.
public enum HarnessProtocol: String, Hashable, Codable, Sendable {
  /// Claude Code: the Anthropic Messages protocol.
  case messages
  /// Codex: the OpenAI Responses protocol.
  case responses
}

/// What one session token of the gateway leads to.
public struct GatewayRoute: Hashable, Sendable {
  public var endpoint: EndpointConfiguration
  public var secret: String?
  /// The model asked of the endpoint, whatever name the harness uses.
  public var model: String

  public init(endpoint: EndpointConfiguration, secret: String?, model: String) {
    self.endpoint = endpoint
    self.secret = secret
    self.model = model
  }
}
