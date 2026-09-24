import Foundation
import VibeDomain

/// Reads `git diff --name-status -z --find-renames`.
///
/// Each file is a status record then its path, or two paths — origin first — for a rename or a
/// copy. Records are separated by NUL, so a path is read exactly as Git wrote it. Every file is
/// counted; only the first `limit` are kept.
enum GitDiffParser {
  static func parse(_ output: Data, limit: Int) -> (files: [CommittedFile], total: Int) {
    let records = output.split(separator: 0, omittingEmptySubsequences: true)
      .map { String(decoding: $0, as: UTF8.self) }
    var files: [CommittedFile] = []
    var total = 0
    var index = 0
    while index < records.count {
      let status = records[index]
      index += 1
      guard let code = status.first else { continue }
      let change: FileChange
      let path: String
      switch code {
      case "R", "C":
        guard index + 1 < records.count else { return (files, total) }
        let from = records[index]
        path = records[index + 1]
        index += 2
        let similarity = Int(status.dropFirst()) ?? 0
        change =
          code == "R"
          ? .renamed(from: from, similarity: similarity)
          : .copied(from: from, similarity: similarity)
      default:
        guard index < records.count else { return (files, total) }
        path = records[index]
        index += 1
        switch code {
        case "A": change = .added
        case "D": change = .deleted
        case "T": change = .typeChanged
        default: change = .modified
        }
      }
      total += 1
      if files.count < limit {
        files.append(CommittedFile(path: path, change: change))
      }
    }
    return (files, total)
  }
}
