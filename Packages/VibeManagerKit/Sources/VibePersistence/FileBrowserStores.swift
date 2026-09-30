import Foundation
import VibeApplication
import VibeDomain

/// Each session's web view (#69), one JSON document per session: `Browser/<session-uuid>.json` for
/// its tabs, `Browser/<session-uuid>.trace.json` for what agents did there.
///
/// Written like the notes: a temporary file in the same folder, then moved over, `0600` in a
/// `0700` folder. A document that cannot be read gives an empty view — it only held where some
/// pages were — and is replaced at the next save.
public actor FileBrowserStore: BrowserStateStore, BrowserActionLogStore {
  private let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  /// `Browser/` next to `sessions.json`.
  public static func defaultDirectory() -> URL {
    FileSessionRepository.defaultStoreURL().deletingLastPathComponent()
      .appendingPathComponent("Browser", isDirectory: true)
  }

  public func load(_ id: SessionID) -> SessionBrowserState {
    read(SessionBrowserState.self, from: stateURL(id)) ?? SessionBrowserState()
  }

  public func save(_ state: SessionBrowserState, for id: SessionID) {
    write(state, to: stateURL(id))
  }

  public func load(_ id: SessionID) -> [BrowserActionRecord] {
    read(TraceDocument.self, from: traceURL(id))?.records ?? []
  }

  public func save(_ records: [BrowserActionRecord], for id: SessionID) {
    guard !records.isEmpty else {
      try? FileManager.default.removeItem(at: traceURL(id))
      return
    }
    write(TraceDocument(records: records), to: traceURL(id))
  }

  /// Both documents: the session is gone, and so is what its web view was.
  public func remove(_ id: SessionID) {
    try? FileManager.default.removeItem(at: stateURL(id))
    try? FileManager.default.removeItem(at: traceURL(id))
  }

  public nonisolated func stateURL(_ id: SessionID) -> URL {
    directory.appendingPathComponent("\(id.rawValue.uuidString).json", isDirectory: false)
  }

  public nonisolated func traceURL(_ id: SessionID) -> URL {
    directory.appendingPathComponent("\(id.rawValue.uuidString).trace.json", isDirectory: false)
  }

  private struct TraceDocument: Codable {
    var version = 1
    var records: [BrowserActionRecord]

    init(records: [BrowserActionRecord]) {
      self.records = records
    }

    private enum CodingKeys: String, CodingKey { case version, records }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      version = (try? container.decode(Int.self, forKey: .version)) ?? 1
      records = (try? container.decode([BrowserActionRecord].self, forKey: .records)) ?? []
    }
  }

  private func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder.browser.decode(type, from: data)
  }

  private func write<Value: Encodable>(_ value: Value, to url: URL) {
    let manager = FileManager.default
    do {
      try manager.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let data = try JSONEncoder.browser.encode(value)
      let temporary = directory.appendingPathComponent(
        ".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
      guard
        manager.createFile(
          atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
      else { return }
      if rename(temporary.path, url.path) != 0 {
        try? manager.removeItem(at: temporary)
      }
    } catch {
      // A lost write costs where some tabs were, and is tried again at the next change.
    }
  }
}

extension JSONEncoder {
  fileprivate static var browser: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var browser: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

/// The choices of Settings › Web View: preferences of this Mac. The sites always allowed are not
/// kept here, where any process of the user could add one (#239): `VaultBrowserPermissionStore`.
@MainActor
public final class UserDefaultsBrowserSettings: BrowserPreferences {
  private let defaults: UserDefaults
  private let agentsKey = "browser.givesAgentsWebView.v1"
  private let showKey = "browser.showsWebViewWhenAgentOpensPage.v1"
  // Named when it was only the terminal's: kept, so that the choice made then still holds (#186).
  private let linksKey = "browser.terminalLinks.v1"

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var givesAgentsWebView: Bool {
    get { defaults.object(forKey: agentsKey) as? Bool ?? true }
    set { defaults.set(newValue, forKey: agentsKey) }
  }

  public var showsWebViewWhenAgentOpensPage: Bool {
    get { defaults.object(forKey: showKey) as? Bool ?? true }
    set { defaults.set(newValue, forKey: showKey) }
  }

  public var links: LinkDestination {
    get {
      defaults.string(forKey: linksKey).flatMap(LinkDestination.init(rawValue:))
        ?? .webView
    }
    set { defaults.set(newValue.rawValue, forKey: linksKey) }
  }
}
