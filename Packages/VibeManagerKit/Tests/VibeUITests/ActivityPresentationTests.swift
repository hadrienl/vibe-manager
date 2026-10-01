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
  @Test("A long name may go to the line after its separators, and only where it is shown")
  func breakable() {
    let shown = ActivityPresentation.breakable("feat/279-a_b.c")
    #expect(shown == "feat/\u{200B}279-\u{200B}a_\u{200B}b.\u{200B}c")
    #expect(shown.replacingOccurrences(of: "\u{200B}", with: "") == "feat/279-a_b.c")
    #expect(ActivityPresentation.breakable("#36") == "#36")
    #expect(ActivityPresentation.breakable("v1.") == "v1.")
  }

  @Test("Under the name: where it belongs, then what was done with it")
  func caption() {
    #expect(ActivityPresentation.caption(branch(webURL: nil)) == "vibe-manager · created")
    let worktree = SessionResource(
      key: "worktree:/w/agent-3", kind: .worktree, label: "agent-3", context: nil,
      target: .folder("/w/agent-3"), involvement: .created, firstSeenAt: Date())
    #expect(ActivityPresentation.caption(worktree) == "created")
  }

  @Test("The help gives the whole name, where it belongs, then where it leads")
  func help() throws {
    let url = try #require(URL(string: "https://github.com/hadrienl/vibe-manager/tree/feat/x"))
    #expect(
      ActivityPresentation.help(branch(webURL: url))
        == "\(longBranch)\nvibe-manager\n\(url.absoluteString)")
    #expect(
      ActivityPresentation.help(branch(webURL: nil))
        == "\(longBranch)\nvibe-manager\n/r/vibe-manager")
    let folder = SessionResource(
      key: "worktree:/w/agent-3", kind: .worktree, label: "agent-3", context: nil,
      target: .folder("/w/agent-3"), involvement: .created, firstSeenAt: Date())
    #expect(ActivityPresentation.help(folder) == "agent-3\n/w/agent-3")
  }

  @Test("Folded, the header's help gives its summary in full before what a click does")
  func headerHelp() {
    let folded = InspectorSectionHeader.help(isCollapsed: true, summary: "12 resources")
    #expect(folded.hasPrefix("12 resources\n"))
    #expect(
      InspectorSectionHeader.help(isCollapsed: true, summary: nil)
        == folded.replacingOccurrences(of: "12 resources\n", with: ""))
    #expect(
      !InspectorSectionHeader.help(isCollapsed: false, summary: "12 resources").contains("12"))
  }

  private let longBranch = "feat/279-activite-sans-troncature-des-ressources-longues"

  private func branch(webURL: URL?) -> SessionResource {
    SessionResource(
      key: "branch:/r/vibe-manager:\(longBranch)", kind: .branch, label: longBranch,
      context: "vibe-manager", target: .branch(repositoryPath: "/r/vibe-manager", webURL: webURL),
      involvement: .created, firstSeenAt: Date())
  }
}
