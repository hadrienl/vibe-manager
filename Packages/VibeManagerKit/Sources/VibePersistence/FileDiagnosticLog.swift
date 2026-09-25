import Darwin
import Foundation
import Security
import VibeApplication
import os

/// Where the diagnostics of one copy of the application are written.
public struct DiagnosticsLocation: Hashable, Sendable {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  /// `~/Library/Logs/Vibe Manager`, where Console.app looks for an application's logs.
  public static func standard() -> DiagnosticsLocation {
    let library =
      FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent("Library", isDirectory: true)
    return DiagnosticsLocation(
      directory: library.appendingPathComponent("Logs/Vibe Manager", isDirectory: true))
  }

  public var applicationLog: URL { directory.appendingPathComponent("app.jsonl") }
  public var hostLog: URL { directory.appendingPathComponent("host.jsonl") }
  var saltURL: URL { directory.appendingPathComponent(".salt") }

  /// Every log file there is, rotated ones included.
  public func logFiles() -> [URL] {
    ["app", "host"].flatMap { base in
      [
        directory.appendingPathComponent("\(base).1.jsonl"),
        directory.appendingPathComponent("\(base).jsonl"),
      ]
    }
    .filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// The key of the session pseudonyms of this Mac: 32 random bytes in `.salt`, `0600`, created
  /// once and never exported. Without it the pseudonyms of the log lead nowhere.
  public func salt() -> Data {
    if let data = try? Data(contentsOf: saltURL), data.count == 32 { return data }
    var bytes = [UInt8](repeating: 0, count: 32)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
      bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
    }
    let data = Data(bytes)
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(
      atPath: saltURL.path, contents: data, attributes: [.posixPermissions: 0o600])
    // Another process may have written its own meanwhile: whichever is on disk is the salt.
    if let written = try? Data(contentsOf: saltURL), written.count == 32 { return written }
    return data
  }
}

/// Whether debug events are kept: `defaults write eu.hadrien.VibeManager DiagnosticsVerbose -bool
/// YES`. Verbose is not indiscreet: debug events are made of the same types as the others.
public enum DiagnosticsVerbosity {
  public static let defaultsKey = "DiagnosticsVerbose"

  public static func minimumLevel(defaults: UserDefaults = .standard) -> DiagnosticLevel {
    defaults.bool(forKey: defaultsKey) ? .debug : .info
  }
}

/// The diagnostics log as JSON lines, one file per process, bounded in size and in age.
///
/// Written in append from one serial queue: a caller never waits for the disk. The file is `0600`
/// in a `0700` folder, flushed to disk only for `error` and `fault`, which are the events a crash
/// that follows would make worth reading. Past `maximumFileSize`, or once its first line is a
/// week old, the file becomes `<name>.1.jsonl`, replacing the previous one, which is also removed
/// once its last line is a week old: nothing older than two weeks is ever kept, and nothing larger
/// than twice `maximumFileSize`.
///
/// A line that cannot be written is counted, and the count is written as an event of its own
/// once writing works again.
public final class FileDiagnosticLog: DiagnosticLog, @unchecked Sendable {
  public static let defaultMaximumFileSize = 5 * 1024 * 1024
  public static let rotationAge: TimeInterval = 7 * 24 * 60 * 60

  private let url: URL
  private let rotatedURL: URL
  private let origin: DiagnosticOrigin
  private let minimumLevel: DiagnosticLevel
  private let maximumFileSize: Int
  private let now: @Sendable () -> Date
  private let queue = DispatchQueue(label: "com.hadrienl.VibeManager.diagnostics")

  // Only touched on `queue`.
  private var descriptor: Int32 = -1
  private var size = 0
  private var openedAt: Date?
  private var dropped = 0

  public init(
    url: URL,
    origin: DiagnosticOrigin,
    minimumLevel: DiagnosticLevel = .info,
    maximumFileSize: Int = FileDiagnosticLog.defaultMaximumFileSize,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.url = url
    rotatedURL = url.deletingPathExtension().appendingPathExtension("1.jsonl")
    self.origin = origin
    self.minimumLevel = minimumLevel
    self.maximumFileSize = maximumFileSize
    self.now = now
  }

  deinit {
    if descriptor >= 0 { close(descriptor) }
  }

  public func record(_ event: DiagnosticEvent) {
    guard event.level >= minimumLevel else { return }
    let line = DiagnosticLine.encode(event, origin: origin)
    let durable = event.level >= .error
    queue.async { self.write(line, durable: durable) }
  }

  /// Waits for every line recorded so far to be written. For tests and for the export.
  public func flush() {
    queue.sync {}
  }

  private func write(_ line: Data, durable: Bool) {
    guard prepare(for: line.count) else {
      dropped += 1
      return
    }
    if dropped > 0 {
      let report = DiagnosticLine.encode(
        DiagnosticEvent(
          at: now(), .lifecycle, .notice, "diagnostics.linesDropped", ["count": .count(dropped)]),
        origin: origin)
      if append(report) { dropped = 0 }
    }
    guard append(line) else {
      dropped += 1
      return
    }
    if durable { fsync(descriptor) }
  }

  private func append(_ data: Data) -> Bool {
    let written = data.withUnsafeBytes { buffer in
      Darwin.write(descriptor, buffer.baseAddress, buffer.count)
    }
    guard written == data.count else { return false }
    size += written
    return true
  }

  /// Opens the file if needed, and rotates it when this line would take it past its bounds.
  private func prepare(for count: Int) -> Bool {
    if descriptor < 0, !open() { return false }
    let tooOld = openedAt.map { now().timeIntervalSince($0) > Self.rotationAge } ?? false
    if size > 0, size + count > maximumFileSize || tooOld {
      close(descriptor)
      descriptor = -1
      _ = rename(url.path, rotatedURL.path)
      if !open() { return false }
    }
    return true
  }

  private func open() -> Bool {
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    removeStaleRotation()
    descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return false }
    fchmod(descriptor, 0o600)
    var status = stat()
    if fstat(descriptor, &status) == 0 {
      size = Int(status.st_size)
      // The first line's date is the file's birth: a file carried over from last week rotates at
      // its first write.
      openedAt =
        size == 0
        ? now()
        : Date(
          timeIntervalSince1970: TimeInterval(status.st_birthtimespec.tv_sec))
    } else {
      size = 0
      openedAt = now()
    }
    return true
  }

  private func removeStaleRotation() {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: rotatedURL.path),
      let modified = attributes[.modificationDate] as? Date,
      now().timeIntervalSince(modified) > Self.rotationAge
    else { return }
    try? FileManager.default.removeItem(at: rotatedURL)
  }
}

/// Every event in the unified log as well, under `eu.hadrien.VibeManager`, one category per
/// module, for Console.app and Instruments. Marked public: its content is safe by construction.
public struct OSLogDiagnosticLog: DiagnosticLog {
  public static let subsystem = "eu.hadrien.VibeManager"

  private let minimumLevel: DiagnosticLevel

  public init(minimumLevel: DiagnosticLevel = .info) {
    self.minimumLevel = minimumLevel
  }

  public func record(_ event: DiagnosticEvent) {
    guard event.level >= minimumLevel else { return }
    let logger = Logger(subsystem: Self.subsystem, category: event.category.rawValue)
    let name = event.nameText
    let fields = DiagnosticLine.summary(event)
    switch event.level {
    case .debug: logger.debug("\(name, privacy: .public) \(fields, privacy: .public)")
    case .info: logger.info("\(name, privacy: .public) \(fields, privacy: .public)")
    case .notice: logger.notice("\(name, privacy: .public) \(fields, privacy: .public)")
    case .error: logger.error("\(name, privacy: .public) \(fields, privacy: .public)")
    case .fault: logger.fault("\(name, privacy: .public) \(fields, privacy: .public)")
    }
  }
}

extension Diagnostics {
  /// The diagnostics of one process of the application: a file in `location`, the unified log,
  /// and pseudonyms keyed by the salt of this Mac.
  public static func standard(
    location: DiagnosticsLocation,
    origin: DiagnosticOrigin,
    minimumLevel: DiagnosticLevel = DiagnosticsVerbosity.minimumLevel()
  ) -> (Diagnostics, FileDiagnosticLog) {
    let file = FileDiagnosticLog(
      url: origin == .app ? location.applicationLog : location.hostLog,
      origin: origin,
      minimumLevel: minimumLevel)
    let log = FanOutDiagnosticLog([file, OSLogDiagnosticLog(minimumLevel: minimumLevel)])
    return (
      Diagnostics(log: log, pseudonym: SessionPseudonymizer(salt: location.salt())), file
    )
  }
}
