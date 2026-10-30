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
}
