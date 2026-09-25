import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@Suite("What the Activity pane says")
struct ActivityPresentationTests {
  private let active = WorkSession(name: "S", status: .active)
  private let archived = WorkSession(name: "S", status: .archived)

  @Test("The summary's state is said in words, never an empty block")
  func statuses() {
    typealias P = ActivityPresentation
    #expect(
      P.summaryStatus(journal: nil, session: active, summariesEnabled: true)
        == .waitingForFirstTurn)
    #expect(P.summaryStatus(journal: nil, session: archived, summariesEnabled: true) == .noJournal)
    var journal = SessionJournal()
    #expect(
      P.summaryStatus(journal: journal, session: active, summariesEnabled: false) == .disabled)
    journal.summary = .unavailable(.outdated)
    #expect(
      P.summaryStatus(journal: journal, session: active, summariesEnabled: true)
        == .unavailable(.outdated))
    #expect(P.sentence(for: .unavailable(.outdated), agentName: "Codex")?.contains("Codex") == true)
    let failedAt = Date()
    journal.summary = .failed(at: failedAt, attempts: 1)
    #expect(
      P.summaryStatus(journal: journal, session: active, summariesEnabled: true)
        == .failed(at: failedAt))
    #expect(P.sentence(for: .normal, agentName: "x") == nil)
  }

  @Test("A link to a known resource shows its short name, and stays a link")
  func links() throws {
    let url = try #require(URL(string: "https://gitlab.com/g/p/-/merge_requests/1315"))
    let resource = try #require(
      ResourceRecognizer.resource(for: url, involvement: .viewed, at: Date()))
    let entry = JournalEntry(text: "Review de \(url.absoluteString)", at: Date(), providerID: nil)
    let text = ActivityPresentation.attributedText(entry, resources: [resource])
    #expect(String(text.characters) == "Review de !1315")
    #expect(text.runs.contains { $0.link == url })
    #expect(ActivityPresentation.links(in: entry.text) == [url])
  }

  @Test("Entries span days: a day before the first entry of each")
  func days() {
    let calendar = Calendar(identifier: .gregorian)
    let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    let entries = [
      JournalEntry(text: "a", at: day.addingTimeInterval(3_600), providerID: nil),
      JournalEntry(text: "b", at: day.addingTimeInterval(90_000), providerID: nil),
    ]
    let (rows, hidden) = ActivityPresentation.entryRows(entries, limit: 30, calendar: calendar)
    #expect(hidden == 0)
    #expect(rows.count == 4)
    let (latest, earlier) = ActivityPresentation.entryRows(entries, limit: 1, calendar: calendar)
    #expect(earlier == 1)
    #expect(latest.last == .entry(entries[1]))
  }

  @Test("VoiceOver reads the kind, the name, where it belongs and what was done with it")
  func spoken() throws {
    let url = try #require(URL(string: "https://github.com/hadrienl/vibe-manager/pull/62"))
    let resource = try #require(
      ResourceRecognizer.resource(for: url, involvement: .created, at: Date()))
    #expect(
      ActivityPresentation.spokenLabel(resource)
        == "Pull request #62, hadrienl/vibe-manager, created")
    #expect(ActivityPresentation.reference(resource) == "hadrienl/vibe-manager#62")
    #expect(ActivityPresentation.copyText(resource) == url.absoluteString)
  }
}
