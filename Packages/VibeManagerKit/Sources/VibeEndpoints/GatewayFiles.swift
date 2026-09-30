import Foundation
import VibeDomain

/// Where the gateway and the application meet: `<data>/Gateway/`.
///
/// No protocol between them, only files. The application writes which session token leads to
/// which endpoint and model (`routes.json`); the gateway reads it, together with `endpoints.json`,
/// and writes where it listens (`gateway.json`). Either can restart without the other, and the
/// gateway keeps serving the sessions the terminal host kept after the application quit.
public struct GatewayLocation: Sendable {
  public let directory: URL
  public let endpointsURL: URL

  public init(directory: URL, endpointsURL: URL) {
    self.directory = directory
    self.endpointsURL = endpointsURL
  }

  public var routesURL: URL { directory.appendingPathComponent("routes.json") }
  public var stateURL: URL { directory.appendingPathComponent("gateway.json") }
  public var lockURL: URL { directory.appendingPathComponent("gateway.lock") }

  /// Private to the user: the routes carry the session tokens.
  public func prepare() throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }
}

/// `routes.json`: the session tokens the gateway accepts.
public struct GatewayRoutesDocument: Codable, Hashable, Sendable {
  public struct Route: Codable, Hashable, Sendable {
    public var endpoint: EndpointID
    public var model: String
    public var session: SessionID?
    public var createdAt: Date

    public init(endpoint: EndpointID, model: String, session: SessionID?, createdAt: Date) {
      self.endpoint = endpoint
      self.model = model
      self.session = session
      self.createdAt = createdAt
    }
  }

  public static let schema = 1

  public var schema: Int
  public var routes: [String: Route]

  public init(routes: [String: Route] = [:]) {
    schema = Self.schema
    self.routes = routes
  }

  public static func read(_ url: URL) -> GatewayRoutesDocument {
    guard let data = try? Data(contentsOf: url),
      let document = try? decoder.decode(GatewayRoutesDocument.self, from: data),
      document.schema <= schema
    else { return GatewayRoutesDocument() }
    return document
  }

  public func write(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(self)
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".routes-\(UUID().uuidString).json")
    guard
      FileManager.default.createFile(
        atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
  }

  static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

/// `gateway.json`: where the running gateway listens.
public struct GatewayState: Codable, Hashable, Sendable {
  public var processIdentifier: Int32
  public var port: UInt16

  public init(processIdentifier: Int32, port: UInt16) {
    self.processIdentifier = processIdentifier
    self.port = port
  }

  public static func read(_ url: URL) -> GatewayState? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(GatewayState.self, from: data)
  }

  public func write(to url: URL) throws {
    try JSONEncoder().encode(self).write(to: url, options: .atomic)
  }

  public var baseURL: URL {
    URL(string: "http://127.0.0.1:\(port)") ?? URL(fileURLWithPath: "/")
  }
}

extension EndpointConfiguration {
  /// What the gateway needs of an endpoint the user declared. `nil` when its URL is unusable.
  public init?(_ endpoint: Endpoint) {
    guard let url = URL(string: endpoint.baseURL.trimmingCharacters(in: .whitespaces)) else {
      return nil
    }
    let wire: EndpointWireProtocol
    switch endpoint.wireProtocol {
    case .chatCompletions: wire = .chatCompletions
    case .responses: wire = .responses
    case .messages: wire = .messages
    }
    let authentication: EndpointAuthentication
    switch endpoint.authentication {
    case .none: authentication = .none
    case .bearer: authentication = .bearer
    case .header(let name): authentication = .header(name: name)
    case .query(let name): authentication = .query(name: name)
    }
    var parameters: [String: JSONValue] = [:]
    let text = endpoint.defaultParameters.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty, case .object(let fields)? = try? JSONValue(parsing: text) {
      parameters = fields
    }
    var headers: [String: String] = [:]
    for header in endpoint.headers where !header.name.isEmpty {
      headers[header.name] = header.value
    }
    let timeouts = EndpointTimeouts(
      connect: .seconds(max(1, endpoint.timeouts.connect)),
      firstByte: .seconds(max(1, endpoint.timeouts.firstByte)),
      idle: .seconds(max(1, endpoint.timeouts.idle)),
      total: .seconds(max(1, endpoint.timeouts.total)))
    self.init(
      baseURL: url, wireProtocol: wire, authentication: authentication, headers: headers,
      defaultParameters: parameters, timeouts: timeouts)
  }
}

/// Where the gateway finds what a token leads to.
public protocol GatewayRouting: Sendable {
  func route(for token: String) async -> GatewayRoute?
}

extension GatewayRouteTable: GatewayRouting {}

/// The routes read from their files, again whenever one of them changed.
///
/// The secret is read from the keychain on each request rather than kept: replacing a key in the
/// settings takes effect on the next turn of every session, and nothing secret stays in memory
/// longer than a request.
public actor FileGatewayRouter: GatewayRouting {
  private let location: GatewayLocation
  private let readEndpoints: @Sendable (URL) throws -> [Endpoint]
  private let secret: @Sendable (EndpointID) -> String?
  private var routes = GatewayRoutesDocument()
  private var endpoints: [EndpointID: Endpoint] = [:]
  private var routesDate: Date?
  private var endpointsDate: Date?

  public init(
    location: GatewayLocation,
    readEndpoints: @escaping @Sendable (URL) throws -> [Endpoint],
    secret: @escaping @Sendable (EndpointID) -> String?
  ) {
    self.location = location
    self.readEndpoints = readEndpoints
    self.secret = secret
  }

  public func route(for token: String) -> GatewayRoute? {
    refresh()
    guard let route = routes.routes[token], let endpoint = endpoints[route.endpoint],
      let configuration = EndpointConfiguration(endpoint)
    else { return nil }
    let secret = endpoint.authentication.needsSecret ? self.secret(endpoint.id) : nil
    return GatewayRoute(endpoint: configuration, secret: secret, model: route.model)
  }

  /// How many tokens lead somewhere: the gateway stops once there is none.
  public func count() -> Int {
    refresh()
    return routes.routes.count
  }

  private func refresh() {
    let routesDate = Self.modificationDate(location.routesURL)
    if routesDate != self.routesDate {
      self.routesDate = routesDate
      routes = GatewayRoutesDocument.read(location.routesURL)
    }
    let endpointsDate = Self.modificationDate(location.endpointsURL)
    if endpointsDate != self.endpointsDate {
      self.endpointsDate = endpointsDate
      let list = (try? readEndpoints(location.endpointsURL)) ?? []
      endpoints = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
  }

  private static func modificationDate(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }
}
