import Foundation
import Testing
import UniformTypeIdentifiers

@testable import VibeApplication

@Suite("What a joined file is, and what may be done with it (#209)")
struct MessageAttachmentTests {
  @Test(
    "Its kind, from its extension",
    arguments: [
      ("png", MessageAttachment.Kind.image), ("HEIC", .image), ("mp3", .audio), ("m4a", .audio),
      ("mov", .video), ("mp4", .video), ("pdf", .pdf), ("txt", .text), ("swift", .text),
      ("json", .text), ("md", .text), ("zip", .other), ("", .other), ("nope-ext", .other),
    ])
  func kindFromExtension(pathExtension: String, kind: MessageAttachment.Kind) {
    #expect(MessageAttachment.kind(forExtension: pathExtension) == kind)
  }

  @Test("Its kind, from a block's media type")
  func kindFromMediaType() {
    #expect(MessageAttachment.kind(forMediaType: "image/jpeg") == .image)
    #expect(MessageAttachment.kind(forMediaType: "application/pdf") == .pdf)
    #expect(MessageAttachment.kind(forMediaType: "nonsense") == .other)
  }

  @Test("A block's image: Claude Code's source, Codex's data URL, nothing else")
  func encodedImage() {
    let claude: [String: Any] = ["source": ["data": "AAAA", "media_type": "image/gif"]]
    #expect(EmbeddedImage.encodedImage(in: claude)?.mediaType == "image/gif")
    let codex: [String: Any] = ["url": "data:image/webp;base64,BBBB"]
    #expect(EmbeddedImage.encodedImage(in: codex)?.base64 == "BBBB")
    #expect(EmbeddedImage.encodedImage(in: codex)?.mediaType == "image/webp")
    #expect(EmbeddedImage.encodedImage(in: ["url": "https://example.com/a.png"]) == nil)
    #expect(EmbeddedImage.encodedImage(in: ["image_url": "data:image/png,raw"]) == nil)
  }

  @Test("A document opens with its application; a program, a script, a folder never do")
  func opening() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("opening-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func file(_ name: String, executable: Bool = false) throws -> URL {
      let url = folder.appendingPathComponent(name)
      try Data("echo hi\n".utf8).write(to: url)
      if executable {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
      }
      return url
    }
    #expect(AttachmentOpening.canOpen(try file("notes.txt")))
    #expect(AttachmentOpening.canOpen(try file("shot.png")))
    #expect(!AttachmentOpening.canOpen(try file("run.command", executable: true)))
    #expect(!AttachmentOpening.canOpen(try file("run.sh", executable: true)))
    #expect(!AttachmentOpening.canOpen(try file("tool", executable: true)))
    #expect(!AttachmentOpening.canOpen(folder))
    let link = folder.appendingPathComponent("innocent.txt")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: folder.appendingPathComponent("run.command"))
    #expect(!AttachmentOpening.canOpen(link))
    #expect(!AttachmentOpening.canOpen(folder.appendingPathComponent("missing.txt")))
    for launcher in ["x.fileloc", "x.webloc", "x.inetloc", "x.pkg", "x.mobileconfig", "x.py"] {
      let url = try file(launcher)
      #expect(!AttachmentOpening.canOpen(url), "\(launcher)")
      #expect(!AttachmentOpening.canPreview(url), "\(launcher)")
    }
    // An archive is shown by Quick Look, but not handed to its application.
    let archive = try file("bundle.zip")
    #expect(AttachmentOpening.canPreview(archive))
    #expect(!AttachmentOpening.canOpen(archive))
  }

  @Test("The web view shows a page or an image, nothing else")
  func webView() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("webview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let image = folder.appendingPathComponent("a.png")
    let text = folder.appendingPathComponent("a.txt")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
    try Data("x".utf8).write(to: text)
    #expect(AttachmentOpening.canShowInWebView(image))
    #expect(!AttachmentOpening.canShowInWebView(text))
  }

  @Test("Only the paths at the end that name files are joined; the text shown loses only them")
  func joinedPaths() {
    let exists: (String) -> Bool = { $0 != "/api/v1/users" && !$0.hasPrefix("/gone") }
    #expect(
      AttachedPaths.split(#"see /tmp/a\ b.png"#, exists: exists).files == [
        URL(fileURLWithPath: "/tmp/a b.png")
      ])
    #expect(AttachedPaths.split("POST /api/v1/users", exists: exists).files.isEmpty)
    #expect(AttachedPaths.split("POST /api/v1/users", exists: exists).text == "POST /api/v1/users")
    #expect(AttachedPaths.split("/tmp/a.txt /gone.txt", exists: exists).files.isEmpty)
    #expect(
      AttachedPaths.split("/gone.txt /tmp/a.txt", exists: exists).files.map(\.path) == [
        "/tmp/a.txt"
      ])
    #expect(AttachedPaths.split("/gone.txt /tmp/a.txt", exists: exists).text == "/gone.txt")
    #expect(
      AttachedPaths.displayText(#"see /tmp/a\ b.png /tmp/c.pdf"#, joinedCount: 1)
        == #"see /tmp/a\ b.png"#)
    #expect(AttachedPaths.displayText(#"see /tmp/a\ b.png /tmp/c.pdf"#, joinedCount: 2) == "see")
    #expect(AttachedPaths.displayText("ends /tmp/x.txt", joinedCount: 0) == "ends /tmp/x.txt")
    #expect(AttachedPaths.displayText("no paths here", joinedCount: 1) == "no paths here")
  }
}
