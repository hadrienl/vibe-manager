import Foundation

/// Where a page comes from, as far as what an agent may do on it is concerned: a scheme, a host and
/// a port, read from a parsed address — never from a string, where `http://localhost@evil.com` is
/// `evil.com`.
public struct BrowserOrigin: Hashable, Codable, Sendable, CustomStringConvertible {
  public let scheme: String
  public let host: String
  public let port: Int?

  public init(scheme: String, host: String, port: Int?) {
    self.scheme = scheme.lowercased()
    self.host = host.lowercased()
    self.port = port
  }

  /// `nil` for an address that has no origin an agent could act on (`about:blank`, `data:`…).
  public init?(url: URL) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased()
    else { return nil }
    if scheme == "file" {
      self.init(scheme: "file", host: "", port: nil)
      return
    }
    guard scheme == "http" || scheme == "https",
      var host = components.host?.lowercased(), !host.isEmpty
    else { return nil }
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    if host.hasSuffix(".") { host.removeLast() }
    self.init(scheme: scheme, host: host, port: components.port)
  }

  /// What a person reads: `github.com`, `localhost:5173`, `local files`.
  public var description: String {
    if scheme == "file" { return "file://" }
    let shownHost = host.contains(":") ? "[\(host)]" : host
    guard let port, port != Self.defaultPort(for: scheme) else { return shownHost }
    return "\(shownHost):\(port)"
  }

  /// The key an "Always Allow" is kept under: the site as a person names it, the port included
  /// when it is not the scheme's own.
  public var grantKey: String {
    "\(scheme)://\(description)"
  }

  /// This Mac: the loopback addresses, `localhost` and its subdomains, and local files. Not
  /// `0.0.0.0`, not the local network, not `.local`: those are other machines, or can be.
  public var isLocal: Bool {
    if scheme == "file" { return true }
    if host == "localhost" || host.hasSuffix(".localhost") { return true }
    if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    // `127.1` and `127.0.0.1` alike: the whole 127/8 block is the loopback.
    let isNumeric = parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    if (2...4).contains(parts.count), isNumeric, parts.first == "127" {
      return true
    }
    return false
  }

  private static func defaultPort(for scheme: String) -> Int? {
    switch scheme {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
  }
}

/// What an agent asks of a page, by what it could do to the user.
public enum BrowserActionClass: String, Hashable, Sendable {
  /// Lists tabs, reads a page, its console, a screenshot.
  case read
  /// Opens, moves, reloads or closes a tab.
  case navigate
  /// Clicks, types, runs JavaScript — as the user, with their cookies.
  case act
}

public enum BrowserActionDecision: Equatable, Sendable {
  case allow
  /// Asked, unless an "Always Allow" covers it.
  case ask
  case deny(reason: String)
}

/// Whether an agent may do something to a page without asking (#69).
///
/// Reading and moving around are free everywhere. Acting is free on this Mac — the preview the
/// agent is building — and asked anywhere else, where it would act as the user. Pure: the whole
/// rule is tested as a table.
public enum BrowserActionPolicy {
  /// The schemes a tab may be sent to. `javascript:` and `data:` would run code or show content
  /// the agent made up under an address the user trusts: refused outright.
  public static let navigableSchemes: Set<String> = ["http", "https", "file", "about"]

  public static func decide(
    _ action: BrowserActionClass,
    url: URL?,
    grants: Set<String>
  ) -> BrowserActionDecision {
    switch action {
    case .read:
      return .allow
    case .navigate:
      guard let url else { return .allow }
      return decideNavigation(to: url)
    case .act:
      guard let url else { return .allow }
      guard let origin = BrowserOrigin(url: url) else {
        // A blank page holds nothing of the user's; any other address without an origin is asked.
        return url.scheme?.lowercased() == "about" ? .allow : .ask
      }
      if origin.isLocal { return .allow }
      return grants.contains(origin.grantKey) ? .allow : .ask
    }
  }

  /// A tab may go to the web, to local files and to a blank page. Another application's address —
  /// `mailto:`, `slack:`, `vscode:` — opens that application, which is asked; code in an address
  /// is refused.
  public static func decideNavigation(to url: URL) -> BrowserActionDecision {
    guard let scheme = url.scheme?.lowercased() else {
      return .deny(reason: "The address has no scheme.")
    }
    if navigableSchemes.contains(scheme) { return .allow }
    if scheme == "javascript" || scheme == "data" || scheme == "blob" {
      return .deny(reason: "A tab cannot be sent to a \(scheme): address.")
    }
    return .ask
  }
}
