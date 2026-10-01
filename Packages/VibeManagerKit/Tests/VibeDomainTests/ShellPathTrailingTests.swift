import Foundation
import Testing

@testable import VibeDomain

@Suite("The paths the composer wrote at the end of a prompt (#209)")
struct ShellPathTrailingTests {
  @Test(
    "Read back as they were escaped, whatever their characters",
    arguments: [
      "/tmp/a.png", "/Users/a/My Shot (1).png", "/tmp/l'été & co #2!.txt", "/tmp/[x]{y}$z`w`.md",
      "/tmp/tab\there.txt", "/tmp/émoji 🎉.pdf", "/tmp/back\\slash.txt", "/tmp/~tilde?.log",
    ])
  func roundTrip(path: String) throws {
    let found = try #require(ShellPath.trailingPaths(in: "Look " + ShellPath.escaped(path)))
    #expect(found.paths == [path])
    #expect(found.body == "Look")
  }

  @Test("Several, in order, the text before them kept")
  func several() throws {
    let text = "Compare\nthese " + ["/a/b c.png", "/d/e.pdf"].map(ShellPath.escaped)
      .joined(separator: " ")
    let found = try #require(ShellPath.trailingPaths(in: text))
    #expect(found.paths == ["/a/b c.png", "/d/e.pdf"])
    #expect(found.body == "Compare\nthese")
  }

  @Test("Nothing but paths")
  func onlyPaths() throws {
    let found = try #require(ShellPath.trailingPaths(in: "/a.png /b.png"))
    #expect(found.paths == ["/a.png", "/b.png"])
    #expect(found.body.isEmpty)
  }

  @Test(
    "Not a path written by the composer",
    arguments: [
      "open /tmp/a.log and tell me", "relative/path.txt", "ends with a space /tmp/a ",
      "a word", "", "/", "cost: 3$", "~/notes.txt", "a lone backslash /tmp/a\\",
    ])
  func notPaths(text: String) {
    #expect(ShellPath.trailingPaths(in: text) == nil)
  }
}
