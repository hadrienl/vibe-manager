import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

extension ConversationEntry {
  /// The text of a prompt as the agent read it; nil for anything else.
  var promptText: String? {
    guard case .userPrompt(let text, _) = content else { return nil }
    return text
  }

  var attachments: [MessageAttachment] {
    guard case .userPrompt(_, let attachments) = content else { return [] }
    return attachments
  }
}

/// The fixtures are shaped after transcripts of Claude Code 2.1.285 and Codex 0.159.2, their words
/// and images replaced: a 1×1 picture stands for each screenshot.
@Suite("The files joined to a prompt, read from its transcript (#209)")
struct MessageAttachmentDecodingTests {
  static let png =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  /// The lines written to a transcript, then read the way the conversation reads it: each record
  /// knows where its line is.
  /// - Parameter chunkSize: small, for the lines to be cut across chunks.
  private func decode(
    _ lines: [String], with decoder: some ConversationDecoding = ClaudeCodeConversationDecoder(),
    chunkSize: Int = 97
  ) async throws -> (entries: [ConversationEntry], file: URL) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("attachments-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("transcript.jsonl")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    for record in await FileTranscriptTail(pollInterval: .seconds(1), chunkSize: chunkSize).read(
      file)
    {
      decoder.consume(record)
    }
    return (decoder.entries, file)
  }

  private func image(_ mediaType: String = "image/png") -> String {
    #"{"type":"image","source":{"type":"base64","media_type":"\#(mediaType)","data":"\#(Self.png)"}}"#
  }

  @Test("An image pasted without a file: where it is in the transcript, never its bytes")
  func pastedImage() async throws {
    let (entries, file) = try await decode([
      #"{"type":"user","uuid":"a","message":{"content":"first"}}"#,
      #"{"type":"user","uuid":"u","message":{"content":[{"type":"text","text":"look at this[Image #1]"},\#(image())]}}"#,
    ])
    let prompt = try #require(entries.last)
    #expect(prompt.promptText == "look at this")
    let attachment = try #require(prompt.attachments.first)
    #expect(prompt.attachments.count == 1)
    #expect(attachment.kind == .image)
    #expect(attachment.name == nil)
    #expect(attachment.file == nil)
    let embedded = try #require(attachment.embeddedImage)
    #expect(embedded.line.file == file)
    #expect(embedded.container == ["message", "content"])
    #expect(embedded.index == 1)
    #expect(embedded.mediaType == "image/png")
    #expect(embedded.readBase64() == Self.png)
  }

  @Test("An image the CLI names by its file keeps both its file and its copy")
  func imageWithItsSource() async throws {
    let (entries, _) = try await decode([
      #"{"type":"user","uuid":"u","message":{"content":[{"type":"text","text":"[Image: source: /tmp/shots/a b.png]"},\#(image())]}}"#
    ])
    try expectNamed(entries)
  }

  @Test("The file of a pasted image, on the meta line the CLI writes after the prompt")
  func imageSourceOnItsOwnLine() async throws {
    let (entries, _) = try await decode([
      #"{"type":"user","uuid":"u","message":{"content":[{"type":"text","text":"[Image #1]"},\#(image())]}}"#,
      #"{"type":"attachment","uuid":"x","attachment":{"type":"hook_success"}}"#,
      #"{"type":"user","uuid":"m","isMeta":true,"message":{"content":[{"type":"text","text":"[Image: source: /tmp/shots/a b.png]"}]}}"#,
      #"{"type":"user","uuid":"r","isMeta":true,"message":{"content":[{"type":"text","text":"a reminder"}]}}"#,
    ])
    #expect(entries.count == 1)
    try expectNamed(entries)
  }

  private func expectNamed(_ entries: [ConversationEntry]) throws {
    let attachment = try #require(entries.first?.attachments.first)
    guard case .fileWithEmbedded(let url, let embedded) = attachment.source else {
      Issue.record("\(attachment.source)")
      return
    }
    #expect(url.path == "/tmp/shots/a b.png")
    #expect(attachment.name == "a b.png")
    #expect(embedded.readBase64() == Self.png)
    #expect(entries.first?.promptText == "")
  }

  @Test("Several images keep their order, each with its own type")
  func severalImages() async throws {
    let (entries, _) = try await decode([
      #"{"type":"user","uuid":"u","message":{"content":[{"type":"text","text":"[Image #1] [Image #2]both"},\#(image()),\#(image("image/jpeg"))]}}"#
    ])
    let attachments = try #require(entries.first?.attachments)
    #expect(attachments.map(\.embeddedImage?.mediaType) == ["image/png", "image/jpeg"])
    #expect(attachments.map(\.embeddedImage?.index) == [1, 2])
    #expect(Set(attachments.map(\.id)).count == 2)
  }

  @Test("A prompt queued during a turn holds its images under `attachment.prompt`")
  func queuedPrompt() async throws {
    let (entries, _) = try await decode([
      #"{"type":"attachment","uuid":"q","attachment":{"type":"queued_command","prompt":[{"type":"text","text":"[Image #3]here too"},\#(image())],"commandMode":"prompt","origin":{"kind":"human"}}}"#
    ])
    let embedded = try #require(entries.first?.attachments.first?.embeddedImage)
    #expect(embedded.container == ["attachment", "prompt"])
    #expect(embedded.readBase64() == Self.png)
  }

  @Test("A placeholder without an image says one was there")
  func placeholderAlone() async throws {
    let (entries, _) = try await decode([
      #"{"type":"user","uuid":"u","message":{"content":[{"type":"text","text":"[Image #1]"}]}}"#
    ])
    #expect(entries.first?.attachments.map(\.source) == [.missing])
  }

  @Test("Files joined by their paths become attachments; the text the agent read keeps them")
  func filesJoinedByPath() async throws {
    let (entries, _) = try await decode([
      #"{"type":"user","uuid":"u","message":{"content":"Read these /Users/a/My\\ Notes\\ \\(1\\).txt /tmp/report.pdf"}}"#,
      #"{"type":"user","uuid":"v","message":{"content":"open /tmp/a.log and tell me"}}"#,
      #"{"type":"user","uuid":"w","message":{"content":"/tmp/only.mp3"}}"#,
    ])
    #expect(entries[0].promptText == #"Read these /Users/a/My\ Notes\ \(1\).txt /tmp/report.pdf"#)
    #expect(
      entries[0].attachments.map(\.file?.path) == ["/Users/a/My Notes (1).txt", "/tmp/report.pdf"])
    #expect(entries[0].attachments.map(\.kind) == [.text, .pdf])
    #expect(AttachedPaths.displayText(entries[0].promptText ?? "") == "Read these")
    #expect(entries[1].attachments.isEmpty)
    #expect(entries[2].attachments.map(\.kind) == [.audio])
    #expect(AttachedPaths.displayText(entries[2].promptText ?? "") == "")
  }

  @Test(
    "Codex: an image joined by its path, relative to the session's folder, and one in the rollout")
  func codex() async throws {
    let item =
      #"{"type":"UserMessage","id":"m","content":[{"type":"local_image","path":"shots/dot.png"},{"type":"image","url":"data:image/png;base64,\#(Self.png)"},{"type":"text","text":"Reply","text_elements":[]}]}"#
    let (entries, _) = try await decode(
      [
        #"{"timestamp":"2026-10-01T19:01:13.000Z","type":"session_meta","payload":{"id":"s","cwd":"/tmp/project","cli_version":"0.159.2"}}"#,
        #"{"timestamp":"2026-10-01T19:01:15.000Z","type":"event_msg","payload":{"type":"item_completed","item":\#(item)}}"#,
      ], with: CodexConversationDecoder())
    let prompt = try #require(entries.first)
    #expect(prompt.promptText == "Reply")
    #expect(prompt.attachments.count == 2)
    #expect(
      prompt.attachments[0].source == .file(URL(fileURLWithPath: "/tmp/project/shots/dot.png")))
    let embedded = try #require(prompt.attachments[1].embeddedImage)
    #expect(embedded.container == ["payload", "item", "content"])
    #expect(embedded.mediaType == "image/png")
    #expect(embedded.readBase64() == Self.png)
  }

  @Test("A transcript rewritten since: the image is no longer read from it")
  func rewrittenTranscript() async throws {
    let (entries, file) = try await decode([
      #"{"type":"user","uuid":"u","message":{"content":[{"type":"text","text":"[Image #1]"},\#(image())]}}"#
    ])
    let embedded = try #require(entries.first?.attachments.first?.embeddedImage)
    try Data(#"{"type":"user","uuid":"x","message":{"content":"something else entirely"}}"#.utf8)
      .write(to: file)
    #expect(embedded.readBase64() == nil)
  }

  @Test("Many screenshots: the conversation holds where they are, not what they are")
  func manyScreenshots() async throws {
    let big = String(repeating: "A", count: 200_000)
    let line =
      #"{"type":"user","uuid":"U","message":{"content":[{"type":"text","text":"[Image #1]"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(big)"}}]}}"#
    let lines = (0..<40).map { line.replacingOccurrences(of: #""U""#, with: "\"u\($0)\"") }
    let (entries, _) = try await decode(lines, chunkSize: TranscriptLineReader.chunkSize)
    #expect(entries.count == 40)
    #expect(entries.allSatisfy { $0.attachments.first?.embeddedImage?.encodedLength == 200_000 })
    // 8 MB of images read; what the entries hold, written out, is a few hundred bytes each.
    #expect(String(describing: entries).utf8.count < 40 * 2_000)
  }
}

@Suite("Where each line of a transcript is (#209)")
struct TranscriptLineLocationTests {
  @Test("Lines located across chunks, a line cut by a chunk's end included, and on resuming")
  func offsets() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("lines-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("t.jsonl")
    let lines = ["{\"a\":1}", "{\"b\":\"a longer line\"}", "{}", "{\"c\":[1,2,3]}"]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    let bytes = try Data(contentsOf: file)
    var reader = TranscriptLineReader(file: file, chunkSize: 5)
    var found: [(Data, UInt64)] = []
    for _ in 0..<40 {
      let reading = reader.readChunk()
      found += zip(reading.lines.map { Data($0) }, reading.lineOffsets)
      if !reading.hasMore { break }
    }
    #expect(found.map { String(decoding: $0.0, as: UTF8.self) } == lines)
    for (line, offset) in found {
      #expect(bytes[Int(offset)..<(Int(offset) + line.count)] == line)
    }
    // Resumed after the second line, the third is located from the start of the file.
    let position = TranscriptPosition(
      inode: try #require(reader.inode), offset: found[2].1,
      fingerprint: bytes[max(0, Int(found[2].1) - 64)..<Int(found[2].1)])
    var resumed = TranscriptLineReader(file: file, from: position)
    #expect(resumed.readChunk().lineOffsets == [found[2].1, found[3].1])
  }
}
