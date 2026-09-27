import Foundation
import Testing

@testable import VibeApplication

@Suite("Typing dropped files and text into a session (#42)")
struct PathInsertionTests {
  private func file(_ path: String) -> DropPayload { .file(URL(fileURLWithPath: path)) }

  private func typed(_ payloads: [DropPayload], bracketed: Bool = false) -> String {
    String(
      decoding: PathInsertion.terminalBytes(for: payloads, bracketed: bracketed), as: UTF8.self)
  }

  @Test(
    "Each character a shell would read otherwise is escaped",
    arguments: [
      ("/a b", #"/a\ b"#),
      ("/l'été", #"/l\'été"#),
      (#"/say "hi""#, #"/say\ \"hi\""#),
      ("/$HOME", #"/\$HOME"#),
      ("/wow!", #"/wow\!"#),
      ("/*.png", #"/\*.png"#),
      ("/(1) [2] {3}", #"/\(1\)\ \[2\]\ \{3\}"#),
      ("/a;b|c&d", #"/a\;b\|c\&d"#),
      ("/<x>?~#`", ##"/\<x\>\?\~\#\`"##),
      (#"/back\slash"#, #"/back\\slash"#),
    ])
  func escaping(path: String, expected: String) {
    #expect(PathInsertion.shellEscaped(path) == expected)
  }

  @Test("Accents and emoji are written as they are, in the form the disk gave")
  func unicodeIsKept() {
    let composed = "/Café 🎉.png"
    let decomposed = "/Cafe\u{301} 🎉.png"
    #expect(PathInsertion.shellEscaped(composed) == #"/Café\ 🎉.png"#)
    #expect(PathInsertion.shellEscaped(decomposed).unicodeScalars.contains("\u{301}"))
  }

  @Test("Several files in the order of the drop, separated by a space and followed by one")
  func orderAndTrailingSpace() {
    #expect(typed([file("/b"), file("/a c"), file("/d")]) == #"/b /a\ c /d "#)
  }

  @Test("A folder is its path")
  func folder() {
    #expect(
      typed([.file(URL(fileURLWithPath: "/Users/me/Work", isDirectory: true))]) == "/Users/me/Work "
    )
  }

  @Test("Inside a bracketed paste when the program asked for one, never followed by Return")
  func bracketed() {
    let bytes = PathInsertion.terminalBytes(for: [file("/x y")], bracketed: true)
    #expect(String(decoding: bytes, as: UTF8.self) == "\u{1B}[200~/x\\ y \u{1B}[201~")
    #expect(!bytes.contains(0x0D))
    #expect(!bytes.contains(0x0A))
  }

  @Test("A path holding a control character is left out and reported")
  func controlCharacter() {
    let trap = file("/tmp/a\u{1B}[201~b")
    let result = PathInsertion.words(for: [file("/ok"), trap])
    #expect(result.words == ["/ok"])
    #expect(result.rejected == [trap])
    #expect(typed([trap]).isEmpty)
  }

  @Test("Text is typed as it is, on one line, without a sequence of its own")
  func text() {
    #expect(typed([.text("https://example.com/a b")]) == "https://example.com/a b ")
    #expect(typed([.text("line one\nline two\r\n\tthree")]) == "line one line two three ")
    #expect(typed([.text("x\u{1B}[201~y")]) == "x[201~y ")
    #expect(typed([.text("  \n ")]).isEmpty)
  }

  @Test("Files and text keep the order they were dropped in")
  func mixed() {
    #expect(typed([file("/a"), .text("see"), file("/b")]) == "/a see /b ")
  }

  @Test(
    "A shell reads back exactly the path that was typed",
    arguments: ["/bin/sh", "/bin/zsh"])
  func shellRoundTrip(shell: String) throws {
    let names = [
      "plain", "with space", "l'apostrophe", #"say "hi""#, "$HOME", "wow!", "*.png",
      "(1) [2] {3}", "a;b|c&d", "<x>?~#`", #"back\slash"#, "Café 🎉", "Cafe\u{301}", "100%^=,",
    ]
    for name in names {
      let path = "/tmp/vibe drop/\(name)"
      let escaped = PathInsertion.shellEscaped(path)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: shell)
      process.arguments = ["-c", "printf '%s' \(escaped)"]
      let output = Pipe()
      process.standardOutput = output
      try process.run()
      process.waitUntilExit()
      let read = String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      #expect(read == path, "\(shell) read \(read) for \(path)")
    }
  }
}

@Suite("Naming what a drop writes (#42)")
struct DropNamingTests {
  @Test("A name keeps no slash, colon, control character or leading dot")
  func sanitized() {
    #expect(DropNaming.sanitized("a/b:c.png", fallback: "x") == "a-b-c.png")
    #expect(DropNaming.sanitized("..hidden", fallback: "x") == "hidden")
    #expect(DropNaming.sanitized("new\nline\u{1B}.txt", fallback: "x") == "new line .txt")
    #expect(DropNaming.sanitized("  ", fallback: "fallback") == "fallback")
    let long = String(repeating: "é", count: 300) + ".png"
    let cut = DropNaming.sanitized(long, fallback: "x")
    #expect(cut.utf8.count <= 200)
    #expect(cut.hasSuffix(".png"))
  }

  @Test("A drop without a name is named after its time")
  func timestamp() {
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    let name = DropNaming.timestampName(
      at: date, fileExtension: "png", timeZone: TimeZone(identifier: "UTC")!)
    #expect(name == "2026-09-21 14.13.20.png")
  }

  @Test("A name taken is suffixed")
  func unique() {
    let taken: Set = ["shot.png", "shot (2).png", "notes"]
    #expect(DropNaming.unique("shot.png", isTaken: taken.contains) == "shot (3).png")
    #expect(DropNaming.unique("notes", isTaken: taken.contains) == "notes (2)")
    #expect(DropNaming.unique("free.png", isTaken: taken.contains) == "free.png")
  }
}
