import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

@Suite("Diagnostic events")
struct DiagnosticEventTests {
  @Test("The home folder is ~, and every name under it is hashed")
  func redactsHome() {
    let path = RedactedPath("/Users/alice/Projects/secret-client/api", home: "/Users/alice")

    #expect(path.rawValue.hasPrefix("~/"))
    #expect(!path.rawValue.contains("alice"))
    #expect(!path.rawValue.contains("Projects"))
    #expect(!path.rawValue.contains("secret"))
    #expect(path.rawValue.split(separator: "/").count == 4)
    // The same folder reads the same twice, a different one differently.
    #expect(path == RedactedPath("/Users/alice/Projects/secret-client/api", home: "/Users/alice"))
    #expect(path != RedactedPath("/Users/alice/Projects/other/api", home: "/Users/alice"))
  }

  @Test("The folders tools are installed in keep their names")
  func keepsToolFolders() {
    #expect(
      RedactedPath("/opt/homebrew/bin/codex", home: "/Users/alice").rawValue
        == "/opt/homebrew/bin/codex")
    #expect(
      RedactedPath("/usr/local/bin/claude", home: "/Users/alice").rawValue
        == "/usr/local/bin/claude")
    #expect(
      RedactedPath("/Users/alice/.local/bin/claude", home: "/Users/alice").rawValue
        .hasPrefix("~/.local/bin/…"))
  }

  @Test("A path outside the home folder and the tool folders is hashed whole")
  func hashesElsewhere() {
    let path = RedactedPath("/Volumes/Client Disk/work", home: "/Users/alice")

    #expect(!path.rawValue.contains("Client"))
    #expect(!path.rawValue.contains("work"))
    #expect(path.rawValue.hasPrefix("/…"))
  }

  @Test("A version is kept only if it looks like one")
  func versions() {
    #expect(DiagnosticVersion("2.1.0-beta+3")?.rawValue == "2.1.0-beta+3")
    #expect(DiagnosticVersion("/Users/alice/bin") == nil)
    #expect(DiagnosticVersion("claude 2.1") == nil)
    #expect(DiagnosticVersion("") == nil)
    #expect(DiagnosticVersion(String(repeating: "1", count: 33)) == nil)
  }

  @Test("A pseudonym is stable for one salt, different for another, and hides the identifier")
  func pseudonyms() {
    let id = SessionID()
    let salt = Data(repeating: 7, count: 32)
    let first = SessionPseudonym(id, salt: salt)

    #expect(first == SessionPseudonym(id, salt: salt))
    #expect(first != SessionPseudonym(id, salt: Data(repeating: 8, count: 32)))
    #expect(first.rawValue.count == 10)
    #expect(!first.rawValue.contains(id.rawValue.uuidString.prefix(8).lowercased()))
  }

  @Test("A line is JSON with the process, the category, the level, the name and the fields")
  func encodesLine() throws {
    let event = DiagnosticEvent(
      at: Date(timeIntervalSince1970: 0), .session, .notice, "session.exited",
      [
        "code": .code(3), "duration": .duration(.milliseconds(1500)), "clean": .flag(false),
        "state": .token(DiagnosticToken("exited")),
      ])
    let data = DiagnosticLine.encode(event, origin: .host)

    #expect(data.last == 0x0A)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["process"] as? String == "host")
    #expect(object["category"] as? String == "session")
    #expect(object["level"] as? String == "notice")
    #expect(object["name"] as? String == "session.exited")
    let fields = try #require(object["fields"] as? [String: Any])
    #expect(fields["code"] as? Int == 3)
    #expect(fields["duration"] as? Double == 1500)
    #expect(fields["clean"] as? Bool == false)
    #expect(fields["state"] as? String == "exited")
  }
}
