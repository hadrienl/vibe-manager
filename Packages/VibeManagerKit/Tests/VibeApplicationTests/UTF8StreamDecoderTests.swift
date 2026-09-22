import Foundation
import Testing
import VibeApplication

@Suite("Decoding a terminal stream")
struct UTF8StreamDecoderTests {
  @Test("A character split between two reads survives them")
  func splitCharacterIsRecovered() {
    var decoder = UTF8StreamDecoder()
    let bytes = [UInt8]("héllo".utf8)
    let split = 2  // Right between the two bytes of "é".

    let first = decoder.decode(Array(bytes[..<split]))
    let second = decoder.decode(Array(bytes[split...]))

    #expect(first == "h")
    #expect(first + second == "héllo")
  }

  @Test("Every split point of a difficult string reassembles the same text")
  func everySplitPointIsHandled() {
    let text = "→ résumé ✅ 🚀 fin"
    let bytes = [UInt8](text.utf8)

    for split in 0...bytes.count {
      var decoder = UTF8StreamDecoder()
      var decoded = decoder.decode(Array(bytes[..<split]))
      decoded += decoder.decode(Array(bytes[split...]))
      decoded += decoder.flush()
      #expect(decoded == text, "split at \(split)")
    }
  }

  @Test("A byte at a time still yields the text")
  func oneByteAtATime() {
    let text = "🚀 ça y est"
    var decoder = UTF8StreamDecoder()
    var decoded = ""

    for byte in [UInt8](text.utf8) {
      decoded += decoder.decode([byte])
    }
    decoded += decoder.flush()

    #expect(decoded == text)
  }

  @Test("An identifier arriving in pieces is readable as one string")
  func identifierIsNotBrokenByAReadBoundary() {
    // What the launch observers actually look for, framed by multi-byte output.
    let text = "✔ session 019ee0a1-06d9-7e52-957b-d61a982d6b43 prête"
    let bytes = [UInt8](text.utf8)
    var decoder = UTF8StreamDecoder()

    var decoded = decoder.decode(Array(bytes[..<3]))
    decoded += decoder.decode(Array(bytes[3...]))

    #expect(decoded.contains("019ee0a1-06d9-7e52-957b-d61a982d6b43"))
  }

  @Test("Plain ASCII is handed over immediately, nothing held back")
  func asciiIsNeverDelayed() {
    var decoder = UTF8StreamDecoder()

    #expect(decoder.decode([UInt8]("ready> ".utf8)) == "ready> ")
    #expect(decoder.flush().isEmpty)
  }

  @Test("A sequence the stream never completes is not swallowed")
  func truncatedSequenceIsReportedAtTheEnd() {
    var decoder = UTF8StreamDecoder()
    let bytes = [UInt8]("é".utf8)

    #expect(decoder.decode([bytes[0]]).isEmpty)
    let tail = decoder.flush()

    #expect(!tail.isEmpty)
    #expect(decoder.flush().isEmpty)
  }

  @Test("Invalid bytes are not mistaken for an unfinished character")
  func invalidBytesAreNotHeld() {
    var decoder = UTF8StreamDecoder()

    let decoded = decoder.decode([0xFF, 0xFE])

    #expect(!decoded.isEmpty)
    #expect(decoder.flush().isEmpty)
  }
}
