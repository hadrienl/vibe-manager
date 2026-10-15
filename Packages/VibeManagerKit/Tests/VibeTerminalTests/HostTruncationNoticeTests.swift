import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminal

/// The losses of output the host reports, as the journal tells them (#367): a client that stays
/// behind must not fill it with one notice per loss, as it did with trims before #364.
@Suite("The output the host lost, in the journal")
struct HostTruncationNoticeTests {
  private let start = ContinuousClock.now

  private func at(_ seconds: Int) -> ContinuousClock.Instant {
    start + .seconds(seconds)
  }

  @Test("The first loss is told at once, the next ones at most once a minute, summed")
  func noticesAreSpacedAndSummed() {
    var notices = TruncationNotices()
    let id = TerminalID()

    #expect(notices.note(10, in: id, at: at(0)) == .init(bytes: 10, count: 1))
    for second in 1..<60 {
      #expect(notices.note(5, in: id, at: at(second)) == nil)
    }
    #expect(notices.note(5, in: id, at: at(60)) == .init(bytes: 300, count: 60))
    #expect(notices.note(7, in: id, at: at(61)) == nil)
    #expect(notices.flush(id) == .init(bytes: 7, count: 1))
    #expect(notices.flush(id) == nil)
  }

  @Test("Each session is spaced on its own")
  func sessionsAreSpacedApart() {
    var notices = TruncationNotices()
    let first = TerminalID()
    let second = TerminalID()

    #expect(notices.note(1, in: first, at: at(0)) != nil)
    #expect(notices.note(1, in: second, at: at(1)) != nil)
    #expect(notices.note(1, in: first, at: at(2)) == nil)
  }

  @Test("A burst of losses leaves two lines in the journal, the last when the session goes")
  func burstOfLossesInTheJournal() async {
    let log = RecordingDiagnosticLog()
    let location = TerminalHostLocation(
      directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vmn-\(UUID().uuidString.prefix(8))", isDirectory: true))
    let supervisor = HostedTerminalSupervisor(
      configuration: HostedTerminalSupervisor.Configuration(
        location: location, launcher: nil, verifier: SameUserPeerVerifier(),
        diagnostics: Diagnostics(log: log, pseudonym: .ephemeral())))
    let id = TerminalID()

    for _ in 0..<100 {
      await supervisor.noteTruncation(of: 8, in: id, at: at(0))
    }
    #expect(log.events(named: "host.outputTruncated").count == 1)

    await supervisor.discard(id)

    let notices = log.events(named: "host.outputTruncated")
    #expect(notices.count == 2)
    #expect(notices.last?.value(of: "bytes") == .bytes(99 * 8))
    #expect(notices.last?.value(of: "losses") == .count(99))
  }
}
