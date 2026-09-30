import Foundation

@testable import VibeApplication

extension TranscriptRecord {
  /// A test line, carried as it is.
  init(text: String) {
    self.init(["line": text])
  }

  var text: String { object["line"] as? String ?? "" }
}

extension TranscriptChunk {
  /// Test lines, the file caught up once they are read.
  static func lines(_ texts: [String]) -> TranscriptChunk {
    .records(texts.map(TranscriptRecord.init(text:)), isCaughtUp: true)
  }
}
