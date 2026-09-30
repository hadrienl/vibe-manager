import Foundation

/// A model server the user declared (#107): reachable over HTTP, speaking one of the protocols the
/// gateway translates, and driven in a session by Claude Code or Codex.
///
/// Its secret is not part of it: it lives in the keychain, under the endpoint's identifier, and is
/// read by the gateway alone.
public struct Endpoint: Identifiable, Hashable, Codable, Sendable {
  public var id: EndpointID
  public var name: String
  /// As the user typed it; checked by `validationIssues`.
  public var baseURL: String
  public var wireProtocol: EndpointWireKind
  public var authentication: EndpointAuthenticationKind
  public var headers: [EndpointHeader]
  /// A JSON object merged into every request, as the user typed it. Empty for none.
  public var defaultParameters: String
  public var timeouts: EndpointTimeoutSettings
  public var harness: EndpointHarnessChoice
  public var models: [EndpointModel]
  /// The last "Test", kept to show its outcome in the list and to warn before a launch.
  public var lastTest: EndpointTestOutcome?

  public init(
    id: EndpointID = EndpointID(),
    name: String,
    baseURL: String,
    wireProtocol: EndpointWireKind,
    authentication: EndpointAuthenticationKind = .bearer,
    headers: [EndpointHeader] = [],
    defaultParameters: String = "",
    timeouts: EndpointTimeoutSettings = EndpointTimeoutSettings(),
    harness: EndpointHarnessChoice = .automatic,
    models: [EndpointModel] = [],
    lastTest: EndpointTestOutcome? = nil
  ) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.wireProtocol = wireProtocol
    self.authentication = authentication
    self.headers = headers
    self.defaultParameters = defaultParameters
    self.timeouts = timeouts
    self.harness = harness
    self.models = models
    self.lastTest = lastTest
  }

  /// The identifier the endpoint is registered under among the agents.
  public var providerID: String { EndpointID.providerPrefix + id.rawValue.uuidString }

  /// The models a session can run: those that call tools. An agent that cannot call a tool
  /// cannot read a file.
  public var agentModels: [EndpointModel] { models.filter(\.supportsTools) }

  /// What prevents the endpoint from being used, in the order a form shows them.
  public var validationIssues: [EndpointValidationIssue] {
    var issues: [EndpointValidationIssue] = []
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.missingName) }
    if let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)),
      let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
      url.host?.isEmpty == false
    {
      if scheme == "http", !Self.isLocal(host: url.host ?? "") { issues.append(.insecureURL) }
    } else {
      issues.append(.invalidURL)
    }
    switch authentication {
    case .header(let name), .query(let name):
      if name.trimmingCharacters(in: .whitespaces).isEmpty {
        issues.append(.missingAuthenticationName)
      }
    case .none, .bearer:
      break
    }
    let parameters = defaultParameters.trimmingCharacters(in: .whitespacesAndNewlines)
    if !parameters.isEmpty {
      let object =
        (try? JSONSerialization.jsonObject(with: Data(parameters.utf8))) as? [String: Any]
      if object == nil { issues.append(.invalidParameters) }
    }
    if agentModels.isEmpty { issues.append(.noToolModel) }
    return issues
  }

  /// Plain HTTP is accepted on this Mac and on the local network only, where a model server
  /// usually has no certificate; anywhere else the secret would cross the network in clear.
  static func isLocal(host: String) -> Bool {
    let host = host.lowercased()
    if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
      || host.hasSuffix(".local")
    {
      return true
    }
    let parts = host.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168)
      || (parts[0] == 172 && (16...31).contains(parts[1]))
  }

  /// The host, for the diagnostics: nothing else of the URL, which may carry a key or a path
  /// naming a customer.
  public var redactedHost: String {
    URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host ?? "?"
  }
}

public struct EndpointID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  /// Read back from an agent identifier, `endpoint.<uuid>`.
  public init?(providerID: String) {
    guard providerID.hasPrefix(Self.providerPrefix),
      let uuid = UUID(uuidString: String(providerID.dropFirst(Self.providerPrefix.count)))
    else { return nil }
    rawValue = uuid
  }

  public static let providerPrefix = "endpoint."

  public var description: String { rawValue.uuidString }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(UUID.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// The protocol an endpoint speaks.
public enum EndpointWireKind: String, Hashable, Codable, Sendable, CaseIterable {
  case chatCompletions
  case responses
  case messages
}

public enum EndpointAuthenticationKind: Hashable, Codable, Sendable {
  case none
  /// `Authorization: Bearer <secret>`.
  case bearer
  /// `<name>: <secret>`.
  case header(name: String)
  /// `?<name>=<secret>`.
  case query(name: String)

  public var needsSecret: Bool { self != .none }
}

public struct EndpointHeader: Hashable, Codable, Sendable {
  public var name: String
  public var value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

/// In seconds, for a form.
public struct EndpointTimeoutSettings: Hashable, Codable, Sendable {
  public var connect: Int
  public var firstByte: Int
  public var idle: Int
  public var total: Int

  public init(connect: Int = 10, firstByte: Int = 120, idle: Int = 60, total: Int = 900) {
    self.connect = connect
    self.firstByte = firstByte
    self.idle = idle
    self.total = total
  }
}

/// The command line agent that drives the endpoint's sessions.
public enum EndpointHarnessChoice: String, Hashable, Codable, Sendable, CaseIterable {
  /// Claude Code for a Messages endpoint, Codex for a Responses one: no translation at all. Claude
  /// Code for the rest, until the benchmark says otherwise.
  case automatic
  case claudeCode
  case codex

  public func resolved(for wire: EndpointWireKind) -> EndpointHarness {
    switch self {
    case .claudeCode: return .claudeCode
    case .codex: return .codex
    case .automatic: return wire == .responses ? .codex : .claudeCode
    }
  }
}

public enum EndpointHarness: String, Hashable, Codable, Sendable {
  case claudeCode
  case codex

  /// The agent identifier of the harness, as recorded on a conversation.
  public var providerID: String {
    switch self {
    case .claudeCode: return "claude-code"
    case .codex: return "codex"
    }
  }
}

public struct EndpointModel: Identifiable, Hashable, Codable, Sendable {
  /// The identifier the endpoint knows it by.
  public var id: String
  public var displayName: String?
  public var contextWindow: Int?
  public var supportsTools: Bool
  public var supportsVision: Bool
  public var supportsReasoning: Bool
  /// Per million tokens, in the currency the user thinks in. `nil`: not given.
  public var inputPricePerMillion: Double?
  public var outputPricePerMillion: Double?

  public init(
    id: String, displayName: String? = nil, contextWindow: Int? = nil, supportsTools: Bool = true,
    supportsVision: Bool = false, supportsReasoning: Bool = false,
    inputPricePerMillion: Double? = nil, outputPricePerMillion: Double? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.contextWindow = contextWindow
    self.supportsTools = supportsTools
    self.supportsVision = supportsVision
    self.supportsReasoning = supportsReasoning
    self.inputPricePerMillion = inputPricePerMillion
    self.outputPricePerMillion = outputPricePerMillion
  }

  /// Below this, the prompt and the tools of a harness leave no room for work.
  public static let minimumAgentContext = 32_768

  public var hasShortContext: Bool {
    guard let contextWindow else { return false }
    return contextWindow < Self.minimumAgentContext
  }
}

/// What the last test of an endpoint found, in short.
public struct EndpointTestOutcome: Hashable, Codable, Sendable {
  public enum Verdict: String, Hashable, Codable, Sendable {
    case passed
    case passedWithWarnings
    case failed
  }

  public var verdict: Verdict
  public var date: Date
  public var model: String?

  public init(verdict: Verdict, date: Date, model: String? = nil) {
    self.verdict = verdict
    self.date = date
    self.model = model
  }
}

public enum EndpointValidationIssue: Hashable, Sendable {
  case missingName
  case invalidURL
  case insecureURL
  case missingAuthenticationName
  case invalidParameters
  case noToolModel
}
