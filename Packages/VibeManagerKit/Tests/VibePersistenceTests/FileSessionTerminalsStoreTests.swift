import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("Keeping each session's drawer of side terminals")
struct FileSessionTerminalsStoreTests {
  private func makeStore() -> (FileSessionTerminalsStore, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeTerminalsStore-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("Terminals", isDirectory: true)
    return (FileSessionTerminalsStore(directory: directory), directory)
  }

  private func mode(of url: URL) throws -> Int? {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue
  }

  @Test("The drawer comes back as it was written, owner only, out of backups")
  func roundTrip() async throws {
    let (store, directory) = makeStore()
    let session = SessionID()
    let terminal = TerminalID()
    let document = SessionTerminalsDocument(
      isVisible: true, height: 300, activeTerminal: terminal,
      terminals: [DrawerTerminalRecord(id: terminal, directory: "/work/app")])

    await store.save(document, for: session)

    #expect(await store.load(session) == document)
    #expect(try mode(of: store.documentURL(session)) == 0o600)
    #expect(try mode(of: store.documentURL(session).deletingLastPathComponent()) == 0o700)
    let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
  }

  @Test("A history is kept byte for byte, and counted without being read")
  func scrollback() async throws {
    let (store, _) = makeStore()
    let session = SessionID()
    let terminal = TerminalID()
    // A sequence cut in two at the end: kept as it is, not decoded.
    let bytes: [UInt8] = Array("\u{1B}[31mred\u{1B}[0m ".utf8) + [0xE2, 0x82]

    await store.saveScrollback(bytes, of: terminal, in: session)

    #expect(await store.loadScrollback(of: terminal, in: session) == bytes)
    #expect(await store.scrollbackByteCount() == bytes.count)
    #expect(try mode(of: store.scrollbackURL(terminal, in: session)) == 0o600)
  }

  @Test("Closing a terminal for good erases its history, and only its")
  func removesOneHistory() async {
    let (store, _) = makeStore()
    let session = SessionID()
    let closed = TerminalID()
    let kept = TerminalID()
    await store.saveScrollback([1, 2, 3], of: closed, in: session)
    await store.saveScrollback([4, 5], of: kept, in: session)

    await store.removeScrollback(of: closed, in: session)

    #expect(await store.loadScrollback(of: closed, in: session) == nil)
    #expect(await store.loadScrollback(of: kept, in: session) == [4, 5])
  }

  @Test("Turning the history off erases every history, and keeps the drawers")
  func removesAllHistories() async {
    let (store, _) = makeStore()
    let first = SessionID()
    let second = SessionID()
    let document = SessionTerminalsDocument(isVisible: true)
    await store.save(document, for: first)
    await store.saveScrollback([1], of: TerminalID(), in: first)
    await store.saveScrollback([2], of: TerminalID(), in: second)

    await store.removeAllScrollback()

    #expect(await store.scrollbackByteCount() == 0)
    #expect(await store.load(first) == document)
  }

  @Test("A deleted session takes its whole drawer with it")
  func removesASession() async {
    let (store, _) = makeStore()
    let session = SessionID()
    let terminal = TerminalID()
    await store.save(SessionTerminalsDocument(isVisible: true), for: session)
    await store.saveScrollback([1], of: terminal, in: session)

    await store.remove(session)

    #expect(await store.load(session) == nil)
    #expect(await store.loadScrollback(of: terminal, in: session) == nil)
  }

  @Test("A document that cannot be read is set aside, never overwritten")
  func setsAsideAnUnreadableDocument() async throws {
    let (store, _) = makeStore()
    let session = SessionID()
    let url = store.documentURL(session)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: url)

    #expect(await store.load(session) == nil)
    await store.save(SessionTerminalsDocument(isVisible: true), for: session)

    let folder = try FileManager.default.contentsOfDirectory(
      atPath: url.deletingLastPathComponent().path)
    let aside = try #require(folder.first { $0.hasPrefix("drawer.unreadable-") })
    #expect(
      try String(contentsOf: url.deletingLastPathComponent().appendingPathComponent(aside))
        == "not json")
  }

  @Test("The history is kept unless turned off, and the answer survives a relaunch")
  @MainActor
  func preferences() {
    let suite = "VibeTerminalPreferences-\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let preferences = UserDefaultsTerminalPreferences(suiteName: suite)
    #expect(preferences.keepsScrollback)

    preferences.keepsScrollback = false

    #expect(UserDefaultsTerminalPreferences(suiteName: suite).keepsScrollback == false)
  }
}
