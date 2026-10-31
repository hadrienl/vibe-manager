import CompanionCore
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
    #expect(page.headers["Content-Type"] == "text/html")
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
}
