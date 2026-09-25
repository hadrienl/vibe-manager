import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("Keeping each session's web view and its trace")
struct FileBrowserStoreTests {
  private func makeStore() throws -> (FileBrowserStore, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeBrowserStore-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("Browser", isDirectory: true)
    return (FileBrowserStore(directory: directory), directory)
  }

  @Test("Tabs, the one in front and the view's visibility come back, owner only")
  func roundTrip() async throws {
    let (store, directory) = try makeStore()
    let id = SessionID()
    let tab = BrowserTab(
      url: URL(string: "http://localhost:5173/")!, title: "Tasks", openedBy: .agent)
    let state = SessionBrowserState(tabs: [tab], activeTabID: tab.id, isVisible: true)
    await store.save(state, for: id)
    #expect(await store.load(id) == state)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.stateURL(id).path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test("A document that cannot be read is an empty view, not an error")
  func unreadable() async throws {
    let (store, directory) = try makeStore()
    let id = SessionID()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: store.stateURL(id))
    #expect(await store.load(id) == SessionBrowserState())
  }

  @Test("The trace comes back after a relaunch, and goes with the session")
  func trace() async throws {
    let (store, _) = try makeStore()
    let id = SessionID()
    let record = BrowserActionRecord(
      date: Date(timeIntervalSince1970: 1_790_000_000), tool: "page_fill", origin: "github.com",
      target: "textbox “Comment” ← hello", decision: .confirmed, succeeded: true)
    await store.save([record], for: id)
    let reloaded = FileBrowserStore(directory: store.traceURL(id).deletingLastPathComponent())
    let records: [BrowserActionRecord] = await reloaded.load(id)
    #expect(records == [record])
    await store.save(SessionBrowserState(isVisible: true), for: id)
    await store.remove(id)
    let after: [BrowserActionRecord] = await store.load(id)
    #expect(after.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.stateURL(id).path))
  }
}
