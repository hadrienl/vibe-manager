import Foundation
import VibeApplication
import VibeDomain

/// Reads what the export is made of from the disk, reduced as it is read.
public enum DiagnosticsCollector {
  /// How far back the logs go in an export.
  public static let logAge: TimeInterval = 7 * 24 * 60 * 60
  /// How far back crash reports go.
  public static let crashReportAge: TimeInterval = 30 * 24 * 60 * 60

  /// The store as sizes, dates and counts: never a session.
  public static func store(
    storeURL: URL,
    notesDirectory: URL,
    statuses: [SessionStatus]
  ) -> DiagnosticSnapshot.Store {
    let manager = FileManager.default
    let backupURL = storeURL.deletingPathExtension().appendingPathExtension("backup.json")
    let folder = storeURL.deletingLastPathComponent()
    let base = storeURL.deletingPathExtension().lastPathComponent
    let corrupt =
      ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? [])
      .filter { $0.hasPrefix(base + ".corrupt-") }.count
    let notes = ((try? manager.contentsOfDirectory(atPath: notesDirectory.path)) ?? [])
      .filter { $0.hasSuffix(".txt") }
    let noteBytes = notes.reduce(0) { total, name in
      total + (size(of: notesDirectory.appendingPathComponent(name)) ?? 0)
    }
    return DiagnosticSnapshot.Store(
      schemaVersion: schemaVersion(of: storeURL),
      sessionsByStatus: Dictionary(grouping: statuses, by: { $0 }).mapValues(\.count),
      storeBytes: size(of: storeURL),
      backupBytes: size(of: backupURL),
      backupModifiedAt: modified(backupURL),
      corruptCopies: corrupt,
      noteFiles: notes.count,
      noteBytes: noteBytes
    )
  }

  /// The log files, keeping only the lines of the last `logAge`. A line is kept whole or not at
  /// all, and only if it is a diagnostic event: the file is the application's, but the export
  /// never carries what it cannot vouch for.
  public static func logs(
    in location: DiagnosticsLocation,
    now: Date = Date()
  ) -> [DiagnosticSnapshot.Attachment] {
    let cutoff = now.addingTimeInterval(-logAge)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return location.logFiles().compactMap { url in
      guard let data = try? Data(contentsOf: url) else { return nil }
      var kept = Data()
      for line in data.split(separator: 0x0A) {
        guard
          let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
          let stamp = object["at"] as? String, let date = formatter.date(from: stamp),
          date >= cutoff, object["name"] is String
        else { continue }
        kept.append(contentsOf: line)
        kept.append(0x0A)
      }
      return DiagnosticSnapshot.Attachment(name: url.lastPathComponent, contents: kept)
    }
  }

  /// The system's crash reports of the application, from the last `crashReportAge`, with every
  /// path under the home folder redacted. They carry stacks and paths, never the environment.
  public static func crashReports(
    in directory: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
    home: String = NSHomeDirectory(),
    now: Date = Date()
  ) -> [DiagnosticSnapshot.Attachment] {
    let cutoff = now.addingTimeInterval(-crashReportAge)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.sorted().compactMap { name in
      guard name.hasPrefix("Vibe Manager"), name.hasSuffix(".ips") else { return nil }
      let url = directory.appendingPathComponent(name)
      guard let date = modified(url), date >= cutoff,
        let text = try? String(contentsOf: url, encoding: .utf8)
      else { return nil }
      return DiagnosticSnapshot.Attachment(
        name: name, contents: Data(redactingPaths(in: text, home: home).utf8))
    }
  }

  /// Every path under `home` in `text`, replaced by its `RedactedPath`, and the user's short name
  /// wherever else it appears.
  public static func redactingPaths(in text: String, home: String) -> String {
    guard home.count > 1 else { return text }
    let escaped = NSRegularExpression.escapedPattern(for: home)
    guard
      let expression = try? NSRegularExpression(pattern: escaped + "(/[^\\s\"'<>,;)\\]]*)?")
    else { return text }
    let source = text as NSString
    var result = ""
    var cursor = 0
    for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
      result += source.substring(
        with: NSRange(location: cursor, length: match.range.location - cursor))
      result += RedactedPath(source.substring(with: match.range), home: home).rawValue
      cursor = match.range.location + match.range.length
    }
    result += source.substring(from: cursor)
    let user = (home as NSString).lastPathComponent
    guard user.count > 2 else { return result }
    return result.replacingOccurrences(of: user, with: "<user>")
  }

  private static func size(of url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
  }

  private static func modified(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }

  private static func schemaVersion(of url: URL) -> Int? {
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["schemaVersion"] as? Int
  }
}

/// Writes a ZIP archive, each file deflated. No tool is run: the archive is built in memory from
/// the files the user has just read, and written in one go.
public enum ZipArchiveWriter {
  public static func archive(_ files: [DiagnosticFile], at date: Date = Date()) -> Data {
    var archive = Data()
    var directory = Data()
    let (time, day) = dosDateTime(date)

    for file in files {
      let name = Data(file.name.utf8)
      let crc = CRC32.checksum(file.contents)
      let deflated = (try? (file.contents as NSData).compressed(using: .zlib) as Data) ?? Data()
      let useDeflate = !file.contents.isEmpty && deflated.count < file.contents.count
      let payload = useDeflate ? deflated : file.contents
      let method: UInt16 = useDeflate ? 8 : 0
      let offset = UInt32(archive.count)

      archive.append(le32(0x0403_4B50))
      archive.append(le16(20))  // version needed
      archive.append(le16(0x0800))  // UTF-8 names
      archive.append(le16(method))
      archive.append(le16(time))
      archive.append(le16(day))
      archive.append(le32(crc))
      archive.append(le32(UInt32(payload.count)))
      archive.append(le32(UInt32(file.contents.count)))
      archive.append(le16(UInt16(name.count)))
      archive.append(le16(0))
      archive.append(name)
      archive.append(payload)

      directory.append(le32(0x0201_4B50))
      directory.append(le16(0x031E))  // made by: Unix, 3.0
      directory.append(le16(20))
      directory.append(le16(0x0800))
      directory.append(le16(method))
      directory.append(le16(time))
      directory.append(le16(day))
      directory.append(le32(crc))
      directory.append(le32(UInt32(payload.count)))
      directory.append(le32(UInt32(file.contents.count)))
      directory.append(le16(UInt16(name.count)))
      directory.append(le16(0))
      directory.append(le16(0))
      directory.append(le16(0))
      directory.append(le16(0))
      directory.append(le32(0o100600 << 16))  // a regular file, 0600
      directory.append(le32(offset))
      directory.append(name)
    }

    let directoryOffset = UInt32(archive.count)
    archive.append(directory)
    archive.append(le32(0x0605_4B50))
    archive.append(le16(0))
    archive.append(le16(0))
    archive.append(le16(UInt16(files.count)))
    archive.append(le16(UInt16(files.count)))
    archive.append(le32(UInt32(directory.count)))
    archive.append(le32(directoryOffset))
    archive.append(le16(0))
    return archive
  }

  private static func le16(_ value: UInt16) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
  }

  private static func le32(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
  }

  private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
    let components = Calendar(identifier: .gregorian).dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    let time =
      UInt16(
        (components.hour ?? 0) << 11 | (components.minute ?? 0) << 5 | (components.second ?? 0) / 2)
    let day = UInt16(
      max(0, (components.year ?? 1980) - 1980) << 9 | (components.month ?? 1) << 5
        | (components.day ?? 1))
    return (time, day)
  }
}

enum CRC32 {
  private static let table: [UInt32] = (0..<256).map { index in
    var value = UInt32(index)
    for _ in 0..<8 {
      value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
    }
    return value
  }

  static func checksum(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
      crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
  }
}
