import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminal

/// What each subscriber of a terminal is served (#248): the view reads the bytes, the exit watch
/// and the pane's status read the state, the activity tracker reads pulses.
@Suite("What each subscriber of a terminal is served")
struct TerminalSubscribersTests {
  private let start = ContinuousClock.now

  private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
    start + .milliseconds(milliseconds)
  }

  @Test("A pulse goes out on the first output, then at most once per interval")
  func pulseGateSpacesPulsesOut() {
    var gate = PulseGate(interval: .milliseconds(250))

    #expect(gate.output(at: at(0)) == .emit)
    #expect(gate.output(at: at(10)) == .schedule(at: at(250)))
    #expect(gate.output(at: at(100)) == .covered)
    #expect(gate.output(at: at(240)) == .covered)
    gate.scheduledPulseFired(at: at(250))
    #expect(gate.output(at: at(300)) == .schedule(at: at(500)))
    gate.scheduledPulseFired(at: at(500))
    #expect(gate.output(at: at(900)) == .emit)
  }

  @Test("The last output of a burst is always followed by a pulse")
  func pulseGateNeverLeavesABurstUnannounced() {
    var gate = PulseGate(interval: .milliseconds(250))
    var pulses = 0
    var planned: ContinuousClock.Instant?

    // A burst of output every 5 ms for a second: pulses at the start, then every interval, and
    // one planned for after the last block.
    for tick in stride(from: 0, through: 1_000, by: 5) {
      if let deadline = planned, deadline <= at(tick) {
        gate.scheduledPulseFired(at: deadline)
        pulses += 1
        planned = nil
      }
      switch gate.output(at: at(tick)) {
      case .emit: pulses += 1
      case .schedule(let deadline): planned = deadline
      case .covered: break
      }
    }

    #expect(planned != nil)
    #expect(pulses == 5)
  }

  @Test("A subscriber of the state is never handed output")
  func stateSubscriberReadsNoOutput() async {
    var subscribers = TerminalSubscribers()
    let state = subscribers.add(.state, hasEnded: false) { _ in }
    let everything = subscribers.add(.everything, hasEnded: false) { _ in }

    for _ in 0..<1_000 {
      _ = subscribers.output([UInt8]("x".utf8), historyDropped: 1)
    }
    subscribers.stateChanged(.exited(code: 0))
    subscribers.finishAll()

    var stateEvents: [TerminalEvent] = []
    for await event in state { stateEvents.append(event) }
    var outputs = 0
    for await event in everything {
      if case .output = event { outputs += 1 }
    }
    #expect(stateEvents == [.stateChanged(.exited(code: 0))])
    // The view's own stream is bounded, and says what it lost rather than growing.
    #expect(outputs > 0)
  }

  @Test("A subscriber of pulses is told of output without its bytes")
  func pulseSubscriberReadsPulses() async {
    var subscribers = TerminalSubscribers()
    let pulses = subscribers.add(.pulses(every: .milliseconds(250)), hasEnded: false) { _ in }

    #expect(subscribers.output([1, 2, 3], historyDropped: 0, at: at(0)).isEmpty)
    let planned = subscribers.output([4], historyDropped: 0, at: at(10))
    #expect(planned.count == 1)
    #expect(planned.first?.deadline == at(250))
    #expect(subscribers.output([5], historyDropped: 0, at: at(20)).isEmpty)
    if let id = planned.first?.subscriberID { subscribers.deliverPulse(to: id, at: at(250)) }
    subscribers.finishAll()

    var events: [TerminalEvent] = []
    for await event in pulses { events.append(event) }
    #expect(events == [.outputPulse, .outputPulse])
  }

  @Test("The last output is noted as it arrives")
  func notesTheLastOutput() {
    var subscribers = TerminalSubscribers()
    #expect(subscribers.lastOutputAt == nil)
    _ = subscribers.output([1], historyDropped: 0, at: at(40))
    #expect(subscribers.lastOutputAt == at(40))
  }

  @Test("A stand-in's stream is relayed with only what the interest reads")
  func relayKeepsWhatTheInterestReads() {
    #expect(TerminalEventInterest.state.translating(.output([1])) == nil)
    #expect(
      TerminalEventInterest.state.translating(.stateChanged(.starting)) == .stateChanged(.starting))
    #expect(
      TerminalEventInterest.pulses(every: .seconds(1)).translating(.output([1])) == .outputPulse)
    #expect(
      TerminalEventInterest.pulses(every: .seconds(1)).translating(
        .historyTruncated(droppedByteCount: 3)) == nil)
    #expect(TerminalEventInterest.everything.translating(.output([1])) == .output([1]))
  }
}

@Suite("Where a history stands in the stream of output")
struct TerminalHistoryOffsetTests {
  @Test("A history that kept everything starts the stream")
  func fullHistoryStartsAtZero() {
    var history = TerminalHistory(limits: .default)
    history.append([UInt8]("hello ".utf8))
    history.append([UInt8]("world".utf8))

    #expect(history.snapshot.startOffset == 0)
    #expect(history.snapshot.endOffset == 11)
  }

  @Test("Trimmed by bytes, by lines and compacted, the offsets still count every byte")
  func offsetsSurviveTrimming() {
    var history = TerminalHistory(
      limits: TerminalScrollbackLimits(maximumLineCount: 20, maximumByteCount: 256))
    var total = 0
    for index in 0..<2_000 {
      let block = [UInt8]("line \(index)\n".utf8)
      total += block.count
      history.append(block)
      let snapshot = history.snapshot
      #expect(snapshot.endOffset == total)
      #expect(snapshot.startOffset == total - snapshot.bytes.count)
    }
    #expect(history.snapshot.startOffset > 0)
  }

  @Test("Bytes lost before they reached the history move no offset")
  func droppedElsewhereMovesNothing() {
    var history = TerminalHistory(limits: .default)
    history.append([1, 2, 3])
    history.noteDropped(1_000)
    #expect(history.snapshot.endOffset == 3)
  }
}

@Suite("A terminal serves each subscriber what it reads")
struct TerminalSessionInterestTests {
  @Test("The exit watch of a talkative process is only told how it ended")
  func stateSubscriberOfARealProcess() async throws {
    let session = try TerminalTestSupport.makeSession(
      script: "for i in $(seq 1 200); do echo line-$i; done")

    let attachment = await session.attach(.state)
    var events: [TerminalEvent] = []
    for await event in attachment.events { events.append(event) }

    #expect(events.allSatisfy { if case .stateChanged = $0 { true } else { false } })
    #expect(events.last == .stateChanged(.exited(code: 0)))
    let historyCount = await session.history().bytes.count
    #expect(historyCount > 0)
    #expect(await session.lastOutputAt() != nil)
    let history = await session.history()
    #expect(history.endOffset == history.bytes.count + history.startOffset)
  }

  @Test("A subscriber of pulses hears of output, and of its last block")
  func pulseSubscriberOfARealProcess() async throws {
    let session = try TerminalTestSupport.makeSession(
      script: "read go; for i in $(seq 1 50); do echo line-$i; done; read end")
    let attachment = await session.attach(.pulses(every: .milliseconds(50)))

    await session.write("go\n")
    var pulses = 0
    for await event in attachment.events {
      if case .output = event { Issue.record("A subscriber of pulses was handed bytes") }
      if event == .outputPulse {
        pulses += 1
        let text = String(decoding: await session.history().bytes, as: UTF8.self)
        // Waits for the pulse that follows the last line rather than for a duration.
        if text.contains("line-50") { break }
      }
    }
    #expect(pulses >= 1)
    await session.stop(gracePeriod: .seconds(2))
  }
}
