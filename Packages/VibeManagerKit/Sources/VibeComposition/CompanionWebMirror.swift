import AppKit
import CompanionCore
import Foundation
import UniformTypeIdentifiers
import VibeBrowser
import VibeCompanionLink
import VibeDomain
import VibeUI
import WebKit

/// A session's web view, kept in step with the phone's (#400). The phone shows the same page in a
/// web view of its own — its scrolling its own, at once — and each side tells the other what its
/// user does: the address, the tab, how far down the page is.
///
/// The Mac sends its tabs and its scroll whenever they change; it takes the phone's the same way.
/// A change one side just received is not sent back to it: neither side echoes the other.
@MainActor
final class CompanionWebMirror {
  /// How often the Mac's web view is read while the phone shows it.
  private static let interval: Duration = .milliseconds(400)
  /// How long after the phone scrolled the Mac's own scroll is taken for that one, not sent back.
  private static let echoWindow: Duration = .milliseconds(900)
  /// A scroll smaller than this is no scroll to tell.
  private static let scrollStep = 0.004

  let sessionID: SessionID
  private weak var appModel: AppModel?
  private let send: @MainActor (RemoteMessage) -> Void
  private var loop: Task<Void, Never>?
  private var lastState: RemoteWebState?
  private var phoneScrolledAt: ContinuousClock.Instant?
  private var grantedFolders: [URL] = []

  init(
    sessionID: SessionID, appModel: AppModel, send: @escaping @MainActor (RemoteMessage) -> Void
  ) {
    self.sessionID = sessionID
    self.appModel = appModel
    self.send = send
  }

  func start() {
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.tick()
        try? await Task.sleep(for: Self.interval)
      }
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
  }

  private var browser: SessionBrowser? {
    appModel?.browser?.browser(for: sessionID)
  }

  private func tick() async {
    guard let browser else { return }
    let active = browser.activeTab
    var scroll = lastState?.scroll ?? 0
    let isEcho = phoneScrolledAt.map { ContinuousClock.now - $0 < Self.echoWindow } ?? false
    if !isEcho, let webView = active?.webView, let fraction = await Self.scroll(of: webView) {
      scroll = fraction
    }
    let state = RemoteWebState(
      sessionID: sessionID.rawValue.uuidString,
      tabs: browser.tabs.map {
        RemoteWebTab(
          id: $0.id.rawValue.uuidString, title: $0.title, url: $0.url.absoluteString,
          isLoading: $0.isLoading)
      },
      activeTabID: active?.id.rawValue.uuidString, canGoBack: active?.canGoBack ?? false,
      canGoForward: active?.canGoForward ?? false, scroll: scroll)
    guard let last = lastState else {
      lastState = state
      send(.webState(state))
      return
    }
    var unscrolled = state
    unscrolled.scroll = last.scroll
    let moved = abs(state.scroll - last.scroll) >= Self.scrollStep
    guard unscrolled != last || moved else { return }
    lastState = state
    send(.webState(state))
  }

  /// How far down the page is, 0 at its top and 1 at its end.
  private static func scroll(of webView: WKWebView) async -> Double? {
    let script = """
      (() => {
        const range = document.documentElement.scrollHeight - window.innerHeight;
        return range > 0 ? window.scrollY / range : 0;
      })()
      """
    return (try? await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient))
      as? Double
  }

  // MARK: - What the phone does

  func perform(_ action: RemoteWebAction) async {
    guard let workspace = appModel?.browser, let browser else { return }
    let tab = browser.activeTab
    switch action {
    case .scrollTo(let fraction):
      phoneScrolledAt = .now
      lastState?.scroll = fraction
      let script = """
        window.scrollTo({top: \(fraction) * (document.documentElement.scrollHeight - window.innerHeight), behavior: 'instant'})
        """
      _ = try? await tab?.webView?.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
    case .navigate(let address):
      guard let url = Self.url(from: address, fileFolders: fileFolders) else { return }
      if let tab {
        // The phone is already there: told back, it would load the page a second time.
        guard !RemoteWebAddress.same(tab.url.absoluteString, url.absoluteString) else { return }
        tab.load(url)
      } else {
        _ = workspace.open(url, in: sessionID, openedBy: .user)
      }
    case .back: tab?.goBack()
    case .forward: tab?.goForward()
    case .reload: tab?.reload()
    case .selectTab(let id):
      guard let uuid = UUID(uuidString: id) else { return }
      browser.activate(BrowserTabID(rawValue: uuid))
    }
  }

  /// What was typed in the address field: an address with its scheme, `localhost:4000` or a
  /// host, as Safari takes them. Only a web page: never a file or another application's scheme,
  /// whatever a paired phone sends.
  /// A file only in one of `fileFolders`: the phone follows a link from one page of an artifact to
  /// another.
  static func url(from address: String, fileFolders: [URL] = []) -> URL? {
    guard let url = RemoteWebAddress.typed(address) else { return nil }
    if url.isFileURL { return isReadable(url, in: fileFolders) ? url : nil }
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    return url
  }

  /// The folders whose files the phone may read: those of the pages this session's tabs have shown
  /// from a file since the phone opened this web view — an artifact and the images, scripts and
  /// pages beside it. Kept when a tab moves on: a page below the first still reaches `../style.css`.
  /// Never any other file of the Mac's, whatever a paired phone asks for.
  var fileFolders: [URL] {
    for tab in browser?.tabs ?? [] where tab.url.isFileURL && !tab.url.hasDirectoryPath {
      let folder = Self.canonical(tab.url.deletingLastPathComponent())
      if !Self.isTooBroad(folder.path), !grantedFolders.contains(folder) {
        grantedFolders.append(folder)
      }
    }
    return grantedFolders
  }

  /// A path as the system spells a file once open, every link resolved. Not
  /// `resolvingSymlinksInPath`, which drops `/private` from `/private/tmp`. A file that does not
  /// exist keeps its name under its folder's real path.
  nonisolated static func canonical(_ url: URL) -> URL {
    let path = url.standardizedFileURL
    if let real = realpath(path.path, nil) {
      defer { free(real) }
      return URL(fileURLWithPath: String(cString: real))
    }
    guard path.path != "/" else { return path }
    return canonical(path.deletingLastPathComponent())
      .appendingPathComponent(path.lastPathComponent)
  }

  /// Whether a folder holds too much else to be opened to the phone for a page in it: the top of
  /// the disk, the shared temporary folders, the home folder and what sits right in it, and
  /// anything in `~/Library`.
  nonisolated static func isTooBroad(_ path: String) -> Bool {
    func resolved(_ path: String) -> String {
      canonical(URL(fileURLWithPath: path)).path
    }
    let folder = resolved(path)
    let home = resolved(NSHomeDirectory())
    let temporary = ["/tmp", "/var/tmp", NSTemporaryDirectory()].map(resolved)
    if temporary.contains(folder) || isInLibrary(folder) { return true }
    if URL(fileURLWithPath: folder).pathComponents.count <= 3 { return true }
    return home == folder || home.hasPrefix(folder + "/")
      || URL(fileURLWithPath: folder).deletingLastPathComponent().path == home
  }

  /// Whether a path, links resolved, is in `~/Library`: the browsers' profiles and cookies, the
  /// other applications' data, iCloud Drive. Never the phone's to read or write in.
  nonisolated static func isInLibrary(_ path: String) -> Bool {
    let library = canonical(URL(fileURLWithPath: NSHomeDirectory())).path + "/Library/"
    return (canonical(URL(fileURLWithPath: path)).path + "/").hasPrefix(library)
  }

  /// Whether a path, links and `..` already resolved, lies in one of `folders` and is no hidden
  /// file or in no hidden folder below it: not a repository's `.env` or `.git`.
  nonisolated private static func lies(_ path: String, in folders: [URL]) -> Bool {
    folders.contains { folder in
      let root = canonical(folder).path
      guard !isTooBroad(root), path.hasPrefix(root + "/") else { return false }
      return !path.dropFirst(root.count + 1).split(separator: "/").contains { $0.hasPrefix(".") }
    }
  }

  /// Whether `url` is a file the phone may read in `folders`, once links and `..` are resolved.
  static func isReadable(_ url: URL, in folders: [URL]) -> Bool {
    url.isFileURL && lies(canonical(url).path, in: folders)
  }

  // MARK: - The phone's requests

  /// A request of the phone's web view for a page of the Mac's own: made here, the answer sent
  /// back whole. Only to the Mac itself or its local network, never anywhere a phone could reach
  /// on its own.
  ///
  /// A file is read only in `fileFolders` (see ``fileFolders``), and only to be shown.
  static func fetch(_ request: RemoteHTTPRequest, fileFolders: [URL] = []) async
    -> RemoteHTTPResponse
  {
    if let url = URL(string: request.url), url.isFileURL {
      return await file(url, for: request, in: fileFolders)
    }
    guard let url = URL(string: request.url), RemoteWebAddress.isMacLocal(url) else {
      return RemoteHTTPResponse(
        id: request.id, status: 0, headers: [:], body: Data(), failure: CompanionStrings.addressRefused)
    }
    var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    for (name, value) in request.headers where !ignoredHeaders.contains(name.lowercased()) {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    do {
      let (data, response) = try await URLSession.shared.data(for: urlRequest)
      let http = response as? HTTPURLResponse
      var headers: [String: String] = [:]
      for (name, value) in http?.allHeaderFields ?? [:] {
        guard let name = name as? String, let value = value as? String,
          !ignoredHeaders.contains(name.lowercased())
        else { continue }
        headers[name] = value
      }
      return RemoteHTTPResponse(
        id: request.id, status: http?.statusCode ?? 200, headers: headers, body: data)
    } catch {
      return RemoteHTTPResponse(
        id: request.id, status: 0, headers: [:], body: Data(),
        failure: error.localizedDescription)
    }
  }

  /// A file of the Mac's for the phone's web view, with its type for WebKit to show it. Its script
  /// runs sandboxed, in an origin of its own: it cannot read the other files the phone may read.
  private static func file(_ url: URL, for request: RemoteHTTPRequest, in folders: [URL]) async
    -> RemoteHTTPResponse
  {
    func refused() -> RemoteHTTPResponse {
      RemoteHTTPResponse(
        id: request.id, status: 0, headers: [:], body: Data(),
        failure: CompanionStrings.addressRefused)
    }
    guard request.method.uppercased() == "GET", isReadable(url, in: folders) else {
      return refused()
    }
    let path = canonical(url)
    let read = await Task.detached { read(path, in: folders) }.value
    switch read {
    case .refused:
      return refused()
    case .status(let status):
      return RemoteHTTPResponse(id: request.id, status: status, headers: [:], body: Data())
    case .data(let data):
      return RemoteHTTPResponse(
        id: request.id, status: 200,
        headers: [
          "Content-Type": contentType(of: path, data: data),
          "Content-Security-Policy": "sandbox allow-scripts allow-forms",
        ],
        body: data)
    }
  }

  private enum FileRead: Sendable {
    case data(Data)
    /// The HTTP status of a file that is not sent.
    case status(Int)
    case refused
  }

  /// The largest file sent: as base64 in one frame, a larger one would not fit
  /// `RemoteFrame.maximumLength` and would close the whole channel.
  nonisolated static let maximumFileLength = 20 * 1024 * 1024

  /// Reads the file that was opened, checked once open: a link swapped after the path was checked
  /// reads nothing outside `folders`.
  nonisolated private static func read(_ path: URL, in folders: [URL]) -> FileRead {
    let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      switch errno {
      case ENOENT, ENOTDIR: return .status(404)
      case ELOOP: return .refused
      default: return .status(403)
      }
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &buffer) == 0,
      lies(String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self), in: folders)
    else { return .refused }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      return .status(404)
    }
    guard info.st_size <= maximumFileLength else { return .status(413) }
    guard let data = try? handle.readToEnd() else { return info.st_size == 0 ? .data(Data()) : .status(403) }
    return .data(data)
  }

  /// What the phone needs to show a file: text said to be UTF-8 when it is, and text with no known
  /// type — a `README`, a `.ts` — shown as text.
  static func contentType(of path: URL, data: Data) -> String {
    let isUTF8 = String(data: data, encoding: .utf8) != nil
    let known =
      path.pathExtension.lowercased() == "wasm"
      ? "application/wasm" : UTType(filenameExtension: path.pathExtension)?.preferredMIMEType
    guard let type = known ?? (isUTF8 ? "text/plain" : nil) else {
      return "application/octet-stream"
    }
    let isText =
      type.hasPrefix("text/") || type.hasSuffix("json") || type.hasSuffix("xml")
      || type.hasSuffix("javascript")
    return isText && isUTF8 ? type + "; charset=utf-8" : type
  }

  /// What the transport sets itself, or what no longer holds once the body is whole.
  private static let ignoredHeaders: Set<String> = [
    "host", "content-length", "connection", "transfer-encoding", "content-encoding",
    "accept-encoding",
  ]
}
