import Foundation
import VibeApplication
import VibeDomain

/// The batches of the automatic archive (#408), one JSON file each:
/// `Automation/Reports/<day>-<id>.json`, written as the journal is — a temporary file in the same
/// folder, synchronized, moved over, `0600` in a `0700` folder. A batch holds sessions' names and
/// sentences a model wrote: the journal's sensitivity.
public actor FileArchiveReportStore: ArchiveReportStore {
  /// The most a batch may weigh: a hundred sessions with full journals stay well under it.
  public static let byteLimit = 16 << 20

  private let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  public static func defaultDirectory(dataFolder: URL) -> URL {
    dataFolder.appendingPathComponent("Automation", isDirectory: true)
      .appendingPathComponent("Reports", isDirectory: true)
  }

  public func batches() -> [ArchiveBatch] {
    files().compactMap { url in
      guard let data = try? Data(contentsOf: url), data.count <= Self.byteLimit,
        let batch = try? JSONDecoder.reports.decode(ArchiveBatch.self, from: data),
        batch.format <= ArchiveBatch.format
      else { return nil }
      return batch
    }
    .sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
  }

  public func save(_ batch: ArchiveBatch) throws {
    do {
      let data = try JSONEncoder.reports.encode(batch)
      guard data.count <= Self.byteLimit else {
        throw ArchiveReportStoreError.cannotWrite("too large")
      }
      try AtomicFileWriter.write(data, to: fileURL(for: batch))
    } catch let error as ArchiveReportStoreError {
      throw error
    } catch {
      throw ArchiveReportStoreError.cannotWrite((error as NSError).localizedDescription)
    }
  }

  public func removeBatches(before date: Date) -> Int {
    var removed = 0
    for url in files() {
      guard let data = try? Data(contentsOf: url),
        let batch = try? JSONDecoder.reports.decode(ArchiveBatch.self, from: data),
        batch.date < date
      else { continue }
      if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
    }
    return removed
  }

  public func removeAll() throws {
    for url in files() {
      try FileManager.default.removeItem(at: url)
    }
  }

  /// The day in the name sorts the files in the Finder; the identifier keeps it unique.
  nonisolated func fileURL(for batch: ArchiveBatch) -> URL {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let day = calendar.dateComponents([.year, .month, .day], from: batch.date)
    let name = String(
      format: "%04d-%02d-%02d-%@.json", day.year ?? 0, day.month ?? 0, day.day ?? 0,
      batch.id.uuidString)
    return directory.appendingPathComponent(name, isDirectory: false)
  }

  private func files() -> [URL] {
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    return urls.filter { $0.pathExtension == "json" }
  }
}

extension JSONEncoder {
  fileprivate static var reports: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var reports: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
