import Foundation

public struct BrowserTabID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(UUID.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  /// The short form an agent reads and types back: the first eight hexadecimal digits.
  public var description: String {
    String(rawValue.uuidString.lowercased().prefix(8))
  }
}

/// One page of a session's web view (#69), as it is kept between launches: where it was and what it
/// was called. Its content is loaded again, never stored.
public struct BrowserTab: Identifiable, Hashable, Codable, Sendable {
  public enum Opener: String, Codable, Sendable {
    case user
    case agent
    case terminalLink
  }

  public let id: BrowserTabID
  public var url: URL
  public var title: String
  public var openedBy: Opener

  public init(id: BrowserTabID = BrowserTabID(), url: URL, title: String = "", openedBy: Opener) {
    self.id = id
    self.url = url
    self.title = title
    self.openedBy = openedBy
  }

  private enum CodingKeys: String, CodingKey {
    case id, url, title, openedBy
  }

  /// An opener written by a later build reads as the user's: it only changes a badge.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(BrowserTabID.self, forKey: .id)
    url = try container.decode(URL.self, forKey: .url)
    title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
    openedBy =
      (try? container.decodeIfPresent(String.self, forKey: .openedBy)).flatMap(Opener.init)
      ?? .user
  }
}

/// A session's web view, as it is kept: its tabs in order, the one in front, and whether the view
/// was open. The ticket's pinned tab is not among the tabs — it follows the ticket.
public struct SessionBrowserState: Hashable, Codable, Sendable {
  public var tabs: [BrowserTab]
  /// `nil` puts the ticket's tab in front, or nothing when there is no ticket.
  public var activeTabID: BrowserTabID?
  public var isVisible: Bool

  public init(tabs: [BrowserTab] = [], activeTabID: BrowserTabID? = nil, isVisible: Bool = false) {
    self.tabs = tabs
    self.activeTabID = activeTabID
    self.isVisible = isVisible
  }

  private enum CodingKeys: String, CodingKey {
    case tabs, activeTabID, isVisible
  }

  /// A tab that cannot be read is dropped, not the whole view: one bad entry must not cost the
  /// others.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let tabs = (try? container.decodeIfPresent([Lenient<BrowserTab>].self, forKey: .tabs)) ?? []
    let read = tabs.compactMap(\.value)
    self.tabs = read
    let active = try? container.decodeIfPresent(BrowserTabID.self, forKey: .activeTabID)
    activeTabID = active.flatMap { id in read.contains { $0.id == id } ? id : nil }
    isVisible = (try? container.decodeIfPresent(Bool.self, forKey: .isVisible)) ?? false
  }
}

private struct Lenient<Value: Decodable>: Decodable {
  let value: Value?

  init(from decoder: any Decoder) throws {
    value = try? Value(from: decoder)
  }
}
