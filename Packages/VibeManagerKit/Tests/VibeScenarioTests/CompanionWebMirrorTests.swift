import CompanionCore
import CompanionWire
import Foundation
import Testing
import VibeCompanionLink

@testable import VibeComposition

/// What the Mac takes from the phone for its web view: a web page, never anything else.
@Suite("The Mac's web view, told by the phone")
@MainActor
struct CompanionWebMirrorTests {
  @Test("Only an http or https address is opened")
  func schemes() {
    #expect(CompanionWebMirror.url(from: "example.com")?.absoluteString == "https://example.com")
    #expect(CompanionWebMirror.url(from: "localhost:4000")?.absoluteString == "http://localhost:4000")
    #expect(CompanionWebMirror.url(from: "HTTPS://example.com") != nil)
    for address in [
      "file:///etc/passwd", "javascript:alert(1)", "javascript://%0aalert(1)",
      "vscode://file/x", "vibemac-http://localhost:4000", "data:text/html,x",
    ] {
      #expect(CompanionWebMirror.url(from: address) == nil, "\(address)")
    }
  }

  @Test("A request refused says so from the catalog")
  func refused() async {
    let request = RemoteHTTPRequest(
      id: 1, url: "https://example.com", method: "GET", headers: [:], body: nil)
    let response = await CompanionWebMirror.fetch(request)
    #expect(response.status == 0)
    #expect(response.failure == CompanionStrings.addressRefused)
  }

  @Test("A file is read only beside a page a tab shows")
  func files() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let artifact = root.appendingPathComponent("artifact", isDirectory: true)
    try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("<p>hi</p>".utf8).write(to: artifact.appendingPathComponent("index.html"))
    try Data("secret".utf8).write(to: root.appendingPathComponent("secret.txt"))
    let folders = [artifact]

    func get(_ url: URL, _ method: String = "GET") async -> RemoteHTTPResponse {
      await CompanionWebMirror.fetch(
        RemoteHTTPRequest(id: 1, url: url.absoluteString, method: method, headers: [:], body: nil),
        fileFolders: folders)
    }
    let page = await get(artifact.appendingPathComponent("index.html"))
    #expect(page.status == 200)
    #expect(page.headers["Content-Type"] == "text/html; charset=utf-8")
    #expect(page.headers["Content-Security-Policy"]?.hasPrefix("sandbox") == true)
    #expect(page.body == Data("<p>hi</p>".utf8))

    for refused in [
      root.appendingPathComponent("secret.txt"),
      URL(fileURLWithPath: artifact.path + "/../secret.txt"),
      URL(fileURLWithPath: "/etc/passwd"),
    ] {
      #expect(await get(refused).failure == CompanionStrings.addressRefused, "\(refused)")
    }
    #expect(await get(artifact.appendingPathComponent("index.html"), "POST").status == 0)
    let unshown = await CompanionWebMirror.fetch(
      RemoteHTTPRequest(
        id: 1, url: artifact.appendingPathComponent("index.html").absoluteString, method: "GET",
        headers: [:], body: nil))
    #expect(unshown.failure == CompanionStrings.addressRefused)

    #expect(
      CompanionWebMirror.url(
        from: artifact.appendingPathComponent("index.html").absoluteString, fileFolders: folders)
        != nil)
    #expect(CompanionWebMirror.url(from: "file:///etc/passwd", fileFolders: folders) == nil)
  }

  private func folder() throws -> (root: URL, artifact: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let artifact = root.appendingPathComponent("artifact", isDirectory: true)
    try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
    return (root, artifact)
  }

  private func get(_ url: URL, in folders: [URL]) async -> RemoteHTTPResponse {
    await CompanionWebMirror.fetch(
      RemoteHTTPRequest(id: 1, url: url.absoluteString, method: "GET", headers: [:], body: nil),
      fileFolders: folders)
  }

  @Test("Neither a link out of the folder nor a hidden file is read")
  func linksAndHidden() async throws {
    let (root, artifact) = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = root.appendingPathComponent("secret.txt")
    try Data("secret".utf8).write(to: secret)
    let link = artifact.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
    let hidden = artifact.appendingPathComponent(".env")
    try Data("KEY=1".utf8).write(to: hidden)
    let git = artifact.appendingPathComponent(".git", isDirectory: true)
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    let config = git.appendingPathComponent("config")
    try Data("x".utf8).write(to: config)
    for refused in [link, hidden, config] {
      #expect(await get(refused, in: [artifact]).failure == CompanionStrings.addressRefused)
    }
  }

  @Test("A hard link to a file elsewhere is not read")
  func hardLink() async throws {
    let (root, artifact) = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = root.appendingPathComponent("id_ed25519")
    try Data("key".utf8).write(to: secret)
    let link = artifact.appendingPathComponent("key.txt")
    try FileManager.default.linkItem(at: secret, to: link)
    #expect(await get(link, in: [artifact]).failure == CompanionStrings.addressRefused)
  }

  @Test("A page of the Mac's too large for a frame answers 413; one at the limit fits the link")
  func largePage() async throws {
    // This test alone registers the page, which another test removing it would pull away.
    #expect(URLProtocol.registerClass(LocalPage.self))
    defer { URLProtocol.unregisterClass(LocalPage.self) }
    func fetch(_ size: Int, saysLength: Bool) async -> RemoteHTTPResponse {
      let url = "http://localhost/vibe-mirror-test/\(saysLength ? "said" : "unsaid")/\(size)"
      return await CompanionWebMirror.fetch(
        RemoteHTTPRequest(id: 1, url: url, method: "GET", headers: [:], body: nil))
    }
    func answer(_ size: Int, saysLength: Bool) async -> String {
      let response = await fetch(size, saysLength: saysLength)
      return "\(response.status) \(response.body.count) \(response.failure ?? "")"
    }
    let limit = CompanionWebMirror.maximumFileLength
    #expect(await answer(5, saysLength: false) == "200 5 ")
    // Bytes of 0xFF, all `/` in base64, which JSON escapes: the most a byte can weigh.
    let page = await fetch(limit, saysLength: true)
    #expect(page.status == 200)
    #expect(page.body.count == limit)
    #expect(try fitsTheLink(page))
    #expect(await answer(limit + 1, saysLength: true) == "413 0 ")
    #expect(await answer(limit + 1, saysLength: false) == "413 0 ")
  }

  @Test("A file at the limit, the worst for JSON, fits a frame and then the link")
  func worstCaseFile() async throws {
    let (root, artifact) = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let blob = artifact.appendingPathComponent("blob.bin")
    try Data(repeating: 0xFF, count: CompanionWebMirror.maximumFileLength).write(to: blob)
    let file = await get(blob, in: [artifact])
    #expect(file.status == 200)
    #expect(try fitsTheLink(file))
  }

  /// Whether a response to a phone fits the channel's frame, and the link the companion's agent
  /// gets it by.
  private func fitsTheLink(_ response: RemoteHTTPResponse) throws -> Bool {
    let message = RemoteMessage.httpResponse(response)
    let wrapped = try JSONEncoder().encode(
      CompanionLinkMessage.remoteSend(peer: "abcdefghij-12345", message))
    return RemoteFrame.encode(message).count - 4 <= RemoteFrame.maximumLength
      && wrapped.count <= CompanionLinkWire.maximumPayloadLength
  }

  @Test("A folder holding too much else opens nothing")
  func broadFolders() async {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    for broad in [
      "/", "/tmp", "/Users", "/private/etc", NSHomeDirectory(), NSTemporaryDirectory(),
      home.appendingPathComponent("Documents").path, home.appendingPathComponent(".ssh").path,
    ] {
      #expect(CompanionWebMirror.isTooBroad(broad), "\(broad)")
    }
    #expect(!CompanionWebMirror.isTooBroad(home.appendingPathComponent("Documents/report").path))
    let key = home.appendingPathComponent(".ssh/id_rsa")
    #expect(!CompanionWebMirror.isReadable(key, in: [home]))
  }

  @Test("Nothing in ~/Library is opened: browsers' profiles, iCloud Drive")
  func library() {
    let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
    for folder in [
      "Application Support", "Application Support/Google/Chrome/Default",
      "Mobile Documents/com~apple~CloudDocs", "Mobile Documents/com~apple~CloudDocs/Site",
    ].map(library.appendingPathComponent) {
      #expect(CompanionWebMirror.isTooBroad(folder.path), "\(folder.path)")
      let page = folder.appendingPathComponent("index.html")
      #expect(!CompanionWebMirror.isReadable(page, in: [folder]), "\(page.path)")
    }
  }

  @Test("A file not sent answers with its status, the channel stays up")
  func statuses() async throws {
    let (root, artifact) = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = await get(artifact.appendingPathComponent("none.json"), in: [artifact])
    #expect(missing.status == 404)
    #expect(missing.failure == nil)
    let large = artifact.appendingPathComponent("demo.mp4")
    #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
    let handle = try FileHandle(forWritingTo: large)
    try handle.truncate(atOffset: UInt64(CompanionWebMirror.maximumFileLength + 1))
    try handle.close()
    let tooLarge = await get(large, in: [artifact])
    #expect(tooLarge.status == 413)
    #expect(tooLarge.body.isEmpty)
  }

  @Test("A file says its type, and text its encoding")
  func types() {
    func type(_ name: String, _ data: Data = Data("é".utf8)) -> String {
      CompanionWebMirror.contentType(of: URL(fileURLWithPath: "/a/" + name), data: data)
    }
    #expect(type("notes.txt") == "text/plain; charset=utf-8")
    #expect(type("README") == "text/plain; charset=utf-8")
    #expect(type("app.wasm", Data([0xFF])) == "application/wasm")
    #expect(type("blob", Data([0xFF])) == "application/octet-stream")
    #expect(type("latin.txt", Data([0xE9])) == "text/plain")
  }
}

/// A page of the Mac's own: `http://localhost/vibe-mirror-test/<said|unsaid>/<size>` answers that
/// many bytes, its length in a header or not.
private final class LocalPage: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "localhost" && request.url?.path.hasPrefix("/vibe-mirror-test/") == true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let size = Int(url.lastPathComponent) else { return }
    let saysLength = url.deletingLastPathComponent().lastPathComponent == "said"
    guard
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: saysLength ? ["Content-Length": String(size)] : [:])
    else { return }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(repeating: 0xFF, count: size))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    // Everything was handed over at the start.
  }
}
