import Foundation
import VibeDomain

/// Where what a drop brings without a file of its own is written, one folder per session (#42): an
/// image dragged out of a web page, a floating screenshot, an attachment Mail promises.
///
/// A file that exists is never copied here: the agent reads and edits the original. What is here
/// goes when the session is archived.
public protocol SessionDropStore: Sendable {
  /// Writes `data` under a name derived from `suggestedName`, made unique in the session's folder.
  func save(_ data: Data, suggestedName: String, for id: SessionID) async throws -> URL
  /// Copies a file or a folder that will not outlive the drop into the session's folder.
  func copy(_ file: URL, suggestedName: String, for id: SessionID) async throws -> URL
  /// Removes the session's folder and everything in it.
  func remove(_ id: SessionID) async
  /// Removes the folders of every session not in `ids`: the leftovers of a crash, or of a session
  /// archived before this store existed.
  func sweep(keeping ids: Set<SessionID>) async
}

/// The names of the files a drop writes (#42): pure, so that what reaches the disk can be tested
/// without one.
public enum DropNaming {
  /// A name that can be written into a terminal and onto the disk: no control character, no
  /// slash or colon, no leading dot that would hide it, and not empty.
  public static func sanitized(_ name: String, fallback: String) -> String {
    let scalars = name.unicodeScalars.map { scalar -> Character in
      if scalar == "/" || scalar == ":" { return "-" }
      let isControl =
        scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
      return isControl ? " " : Character(scalar)
    }
    var cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    while cleaned.hasPrefix(".") { cleaned.removeFirst() }
    cleaned = cleaned.trimmingCharacters(in: .whitespaces)
    // Well under the 255 bytes a file name may take, suffix included.
    while cleaned.utf8.count > 200 {
      let ext = (cleaned as NSString).pathExtension
      let stem = (cleaned as NSString).deletingPathExtension
      guard !stem.isEmpty else {
        cleaned.removeLast()
        continue
      }
      cleaned = String(stem.dropLast()) + (ext.isEmpty ? "" : ".\(ext)")
    }
    return cleaned.isEmpty ? fallback : cleaned
  }

  /// "2026-09-26 10.12.03.png": what a drop without a name of its own is called, in local time.
  public static func timestampName(
    at date: Date, fileExtension: String, timeZone: TimeZone = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let stem = formatter.string(from: date)
    return fileExtension.isEmpty ? stem : "\(stem).\(fileExtension)"
  }

  /// `name`, or "name (2).ext", "name (3).ext"… when it is taken.
  public static func unique(_ name: String, isTaken: (String) -> Bool) -> String {
    guard isTaken(name) else { return name }
    let ext = (name as NSString).pathExtension
    let stem = (name as NSString).deletingPathExtension
    var index = 2
    while true {
      let candidate = "\(stem) (\(index))" + (ext.isEmpty ? "" : ".\(ext)")
      if !isTaken(candidate) { return candidate }
      index += 1
    }
  }
}
