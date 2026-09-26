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

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
  for _ in 0..<200 {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

@Suite("The links of the summary")
@MainActor
struct SessionJournalLinkTests {
  @Test("A link of the summary opens in the session's web view, not in the default browser")
  func opensInWebView() async {
    let opener = FakeOpener()
    let journal = makeJournal(opener: opener)
    let session = SessionID()
    var shown: [(URL, SessionID)] = []
    journal.openInWebView = { url, id in
      shown.append((url, id))
      return true
    }
    let url = URL(string: "https://github.com/o/r/pull/3")!
    journal.openLink(url, from: session)
    #expect(shown.map(\.0) == [url])
    #expect(shown.map(\.1) == [session])
    try? await Task.sleep(for: .milliseconds(50))
    #expect(opener.opened.isEmpty)
  }

  @Test("Without a web view, the default browser shows the link")
  func fallsBackToBrowser() async {
    let opener = FakeOpener()
    let journal = makeJournal(opener: opener)
    journal.openInWebView = { _, _ in false }
    journal.openLink(URL(string: "https://example.com/a")!, from: SessionID())
    #expect(await eventually { opener.opened == ["/a"] })
  }

  @Test("Open in Browser keeps going to the default browser")
  func openInBrowser() async {
    let opener = FakeOpener()
    let journal = makeJournal(opener: opener)
    var shown = 0
    journal.openInWebView = { _, _ in
      shown += 1
      return true
    }
    journal.openInBrowser(URL(string: "https://example.com/b")!)
    #expect(await eventually { opener.opened == ["/b"] })
    #expect(shown == 0)
  }

  @Test("A link that is not of the web opens nowhere")
  func refusesOtherSchemes() async {
    let opener = FakeOpener()
    let journal = makeJournal(opener: opener)
    var shown = 0
    journal.openInWebView = { _, _ in
      shown += 1
      return true
    }
    journal.openLink(URL(string: "file:///Applications/Calculator.app")!, from: SessionID())
    journal.openLink(URL(string: "x-apple.systempreferences:com.apple")!, from: SessionID())
    try? await Task.sleep(for: .milliseconds(50))
    #expect(shown == 0)
    #expect(opener.opened.isEmpty)
  }
}
