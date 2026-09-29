import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// Reads nothing: the links are what is tested, not the journal.
private struct EmptyJournalReader: SessionJournalReading {
  func read(_ session: WorkSession, from cursors: [String: TranscriptCursor]) -> TranscriptReading {
    TranscriptReading(events: [], cursors: cursors, foundTranscript: false)
  }

  func transcriptDirectories(for session: WorkSession) -> [String] { [] }
}

private struct NoSummarizers: SessionSummarizerResolving {
  func summarizer(for providerID: String) async -> (any SessionSummarizing)? { nil }
}

private struct UnknownRepositories: RepositoryIdentityResolving {
  func identity(ofDirectory path: String) async -> RepositoryIdentity? { nil }
}

@MainActor
private func makeJournal(opener: FakeOpener) -> SessionJournalModel {
  SessionJournalModel(
    monitor: SessionJournalMonitor(
      store: InMemorySessionJournalStore(), reader: EmptyJournalReader(),
      repositories: UnknownRepositories(), summarizers: NoSummarizers()),
    preferences: InMemoryJournalPreferences(), opener: opener)
}

@Suite("The links of the summary", .timeLimit(.minutes(2)))
@MainActor
struct SessionJournalLinkTests {
  @Test("A link of the summary follows the session's rule, ⌥ read from the click (#186)")
  func followsTheRule() async {
    let opener = FakeOpener()
    let journal = makeJournal(opener: opener)
    let session = SessionID()
    var routed: [(URL, LinkGesture, SessionID)] = []
    journal.route = { routed.append(($0, $1, $2)) }
    let url = URL(string: "https://github.com/o/r/pull/3")!
    journal.openLink(url, from: session)
    journal.isOptionKeyDown = { true }
    journal.openLink(url, from: session)
    #expect(routed.map(\.0) == [url, url])
    #expect(routed.map(\.1) == [.click(alternate: false), .click(alternate: true)])
    #expect(routed.map(\.2) == [session, session])
    try? await Task.sleep(for: .milliseconds(50))
    #expect(opener.opened.isEmpty)
  }

  @Test("Without the session's rule, the default browser shows the link")
  func fallsBackToBrowser() async {
    let opener = FakeOpener()
    let journal = makeJournal(opener: opener)
    journal.openLink(URL(string: "https://example.com/a")!, from: SessionID())
    await waitUntil("the first link is opened") { opener.opened == ["/a"] }
  }

  @Test("A link's menu offers the web view only when the session has one, and says where")
  func menuActions() {
    let journal = makeJournal(opener: FakeOpener())
    let session = SessionID()
    let url = URL(string: "https://example.com/b")!
    #expect(journal.linkActions(for: url, in: session) == [.openInExternalBrowser, .copy])
    journal.hasWebView = { $0 == session }
    #expect(
      journal.linkActions(for: url, in: session) == [
        .openInWebView, .openInNewTab, .openInExternalBrowser, .copy,
      ])
    var routed: [LinkGesture] = []
    journal.route = { _, gesture, _ in routed.append(gesture) }
    journal.perform(.openInExternalBrowser, on: url, from: session)
    journal.perform(.openInNewTab, on: url, from: session)
    journal.perform(.openInWebView, on: url, from: session)
    #expect(routed == [.browser, .newTab, .webView])
  }

  @Test("A link that is not of the web opens nowhere")
  func refusesOtherSchemes() async {
    let opener = FakeOpener()
    let journal = makeJournal(opener: opener)
    var routed = 0
    journal.route = { _, _, _ in routed += 1 }
    journal.openLink(URL(string: "file:///Applications/Calculator.app")!, from: SessionID())
    journal.openLink(URL(string: "x-apple.systempreferences:com.apple")!, from: SessionID())
    journal.openLink(URL(string: "mailto:a@example.com")!, from: SessionID())
    try? await Task.sleep(for: .milliseconds(50))
    #expect(routed == 0)
    #expect(opener.opened.isEmpty)
    #expect(journal.linkActions(for: URL(string: "mailto:a@example.com")!, in: SessionID()) == [.copy])
  }
}
