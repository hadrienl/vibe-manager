import Foundation
import VibeApplication
import VibeDomain

/// Each session's drawer of side terminals (#43): `Terminals/<session-uuid>/drawer.json` for its
/// tabs, and `Terminals/<session-uuid>/<terminal-uuid>.scrollback` for what each of them showed.
///
/// Written like the notes: a temporary file in the same folder, synchronized, then moved over,
/// `0600` in `0700` folders. The whole folder is kept out of backups — a history can hold a token
/// a command printed, and has no business in Time Machine (ADR 0030). A document that cannot be
/// read is set aside rather than overwritten, so that nothing is lost to a bug of this build.
public actor FileSessionTerminalsStore: SessionTerminalsStore {
  private let directory: URL
  private var isRootPrepared = false

  public init(directory: URL) {
    self.directory = directory
  }

  /// `Terminals/` next to `sessions.json`.
  public static func defaultDirectory() -> URL {
    FileSessionRepository.defaultStoreURL().deletingLastPathComponent()
      .appendingPathComponent("Terminals", isDirectory: true)
  }

  public func load(_ session: SessionID) -> SessionTerminalsDocument? {
    let url = documentURL(session)
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let document = try? JSONDecoder().decode(SessionTerminalsDocument.self, from: data),
      document.schema <= SessionTerminalsDocument.currentSchema
    else {
      setAside(url)
      return nil
    }
    return document
  }

  public func save(_ document: SessionTerminalsDocument, for session: SessionID) {
    guard let data = try? Self.encoder.encode(document) else { return }
    write(data, to: documentURL(session))
  }

  public func loadScrollback(of terminal: TerminalID, in session: SessionID) -> [UInt8]? {
    guard let data = try? Data(contentsOf: scrollbackURL(terminal, in: session)) else {
      return nil
    }
    return [UInt8](data)
  }

  public func saveScrollback(_ bytes: [UInt8], of terminal: TerminalID, in session: SessionID) {
    let url = scrollbackURL(terminal, in: session)
    guard !bytes.isEmpty else {
      try? FileManager.default.removeItem(at: url)
      return
    }
    write(Data(bytes), to: url)
  }

  public func removeScrollback(of terminal: TerminalID, in session: SessionID) {
    try? FileManager.default.removeItem(at: scrollbackURL(terminal, in: session))
  }

  public func removeAllScrollback() {
    for file in scrollbackFiles() {
      try? FileManager.default.removeItem(at: file)
    }
  }

  public func remove(_ session: SessionID) {
    try? FileManager.default.removeItem(at: sessionDirectory(session))
  }

  public func scrollbackByteCount() -> Int {
    scrollbackFiles().reduce(0) { total, file in
      total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
  }

  public nonisolated func documentURL(_ session: SessionID) -> URL {
    sessionDirectory(session).appendingPathComponent("drawer.json", isDirectory: false)
  }

  public nonisolated func scrollbackURL(_ terminal: TerminalID, in session: SessionID) -> URL {
    sessionDirectory(session).appendingPathComponent(
      "\(terminal.rawValue.uuidString).scrollback", isDirectory: false)
  }

  private nonisolated func sessionDirectory(_ session: SessionID) -> URL {
    directory.appendingPathComponent(session.rawValue.uuidString, isDirectory: true)
  }

  private func scrollbackFiles() -> [URL] {
    let manager = FileManager.default
    guard
      let sessions = try? manager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    return sessions.flatMap { folder in
      ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]))
        ?? [])
        .filter { $0.pathExtension == "scrollback" }
    }
  }

  private func write(_ data: Data, to url: URL) {
    prepareRoot()
    do {
      try AtomicFileWriter.write(data, to: url)
    } catch {
      // A lost write costs where some tabs were, or a history, and is tried again at the next
      // change.
    }
  }

  /// Created `0700` and excluded from backups once, before the first file is written in it.
  private func prepareRoot() {
    guard !isRootPrepared else { return }
    let manager = FileManager.default
    if !manager.fileExists(atPath: directory.path) {
      try? manager.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    var root = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? root.setResourceValues(values)
    isRootPrepared = true
  }

  /// Keeps a document this build cannot read beside it, dated, rather than writing over it.
  private func setAside(_ url: URL) {
    let stamp = Int(Date().timeIntervalSince1970)
    let aside = url.deletingLastPathComponent().appendingPathComponent(
      "drawer.unreadable-\(stamp).json", isDirectory: false)
    try? FileManager.default.moveItem(at: url, to: aside)
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

/// Whether the side terminals' history is kept on disk, across launches. On unless turned off.
@MainActor
public final class UserDefaultsTerminalPreferences: TerminalPreferences {
  private let key = "terminals.drawer.keepsScrollback.v1"
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var keepsScrollback: Bool {
    get { defaults.object(forKey: key) as? Bool ?? true }
    set { defaults.set(newValue, forKey: key) }
  }
}
