import Foundation
import Testing
import VibeApplication

@testable import VibePersistence

@Suite("Keeping the automatic archive's rules (#405)")
struct FileArchiveRuleStoreTests {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ArchiveRules-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private let rule = StoredArchiveRule(
    text: #"rule "Vertes" archive done sessions where badge.color = #1E7F4D on weekly friday at 18:00"#,
    state: .active, sentence: "Archive les vertes le vendredi", agent: "claude",
    createdAt: Date(timeIntervalSince1970: 1_792_000_000),
    activatedAt: Date(timeIntervalSince1970: 1_792_000_000))

  @Test("What is written comes back, in Automation/archive-rules.json")
  func roundTrip() async throws {
    let base = try folder()
    defer { try? FileManager.default.removeItem(at: base) }
    let url = FileArchiveRuleStore.defaultURL(dataFolder: base)
    #expect(url.path.hasSuffix("Automation/archive-rules.json"))
    let store = FileArchiveRuleStore(url: url)
    #expect(try await store.load() == ArchiveRuleSet())
    let protection = StoredArchiveProtection(
      text: #"protect where project = "client-x""#, sentence: "sauf client-x")
    let rule = self.rule
    try await store.update { set in
      set.rules = [rule]
      set.protections = [protection]
      set.notifies = false
    }
    let read = try await FileArchiveRuleStore(url: url).load()
    #expect(read.rules == [rule])
    #expect(read.protections == [protection])
    #expect(!read.notifies)
  }

  @Test("A file this version cannot read is never written over")
  func unreadableIsKept() async throws {
    let base = try folder()
    defer { try? FileManager.default.removeItem(at: base) }
    let url = FileArchiveRuleStore.defaultURL(dataFolder: base)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let later = Data(#"{"format": 2, "rules": []}"#.utf8)
    try later.write(to: url)
    let store = FileArchiveRuleStore(url: url)
    await #expect(throws: FileArchiveRuleStore.Unreadable.self) { try await store.load() }
    await #expect(throws: FileArchiveRuleStore.Unreadable.self) {
      try await store.update { $0.notifies = false }
    }
    #expect(try Data(contentsOf: url) == later)
  }

  @Test("A state written by a later version reads as paused; a rule that no longer reads never runs")
  func tolerant() async throws {
    let base = try folder()
    defer { try? FileManager.default.removeItem(at: base) }
    let url = FileArchiveRuleStore.defaultURL(dataFolder: base)
    let store = FileArchiveRuleStore(url: url)
    var broken = rule
    broken.text = "rule \"Vertes\" archive done sessions on fortnightly"
    let rules = [rule, broken]
    try await store.update { $0.rules = rules }
    let text = try String(contentsOf: url, encoding: .utf8)
      .replacingOccurrences(of: #""state" : "active""#, with: #""state" : "sleeping""#)
    try Data(text.utf8).write(to: url)
    let read = try await store.load()
    #expect(read.rules.map(\.state) == [.paused, .paused])
    #expect(read.rules[1].rule == nil)
    #expect(!read.rules[1].runs)
  }

  @Test("Two copies of the application claim a time once, through the file")
  func claimedOnceAcrossCopies() async throws {
    let base = try folder()
    defer { try? FileManager.default.removeItem(at: base) }
    let url = FileArchiveRuleStore.defaultURL(dataFolder: base)
    let rule = self.rule
    try await FileArchiveRuleStore(url: url).update { $0.rules = [rule] }
    struct Clock: SessionClock {
      func now() -> Date { Date(timeIntervalSince1970: 1_792_000_000 + 7 * 86_400) }
    }
    let first = ArchiveRuleScheduler(store: FileArchiveRuleStore(url: url), clock: Clock())
    let second = ArchiveRuleScheduler(store: FileArchiveRuleStore(url: url), clock: Clock())
    async let one = first.claimDueRuns()
    async let two = second.claimDueRuns()
    let runs = try await one + two
    #expect(runs.count == 1)
  }
}
