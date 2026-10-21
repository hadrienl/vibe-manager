import CompanionCore
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func mac(online: Bool, seen: TimeInterval) -> CompanionMac {
  CompanionMac(
    installationID: "A", name: "MacBook", version: "1.0.2", buildLabel: "#347 abc1234",
    online: online, lastSeen: now.addingTimeInterval(-seen))
}

@Test("A Mac is connected while online and seen less than 20 minutes ago")
func macPresence() {
  #expect(CompanionPresence.isConnected(mac(online: true, seen: 12), now: now))
  #expect(CompanionPresence.isConnected(mac(online: true, seen: 19 * 60), now: now))
  #expect(!CompanionPresence.isConnected(mac(online: true, seen: 20 * 60), now: now))
  #expect(!CompanionPresence.isConnected(mac(online: false, seen: 12), now: now))
  // The heartbeat comes well within the tolerance, so a Mac that is there never looks gone.
  #expect(CompanionPresence.heartbeat < CompanionPresence.tolerance)
}

@Test("Each type of record has a name of its own, so a ping and its pong never collide")
func recordNames() {
  let ping = CompanionRecord.ping(CompanionPing(nonce: "7F3A", deviceName: "iPhone", sentAt: now))
  let pong = CompanionRecord.pong(CompanionPong(nonce: "7F3A", macID: "A", receivedAt: now))
  #expect(ping.recordName == "ping-7F3A")
  #expect(pong.recordName == "pong-7F3A")
  #expect(CompanionRecord.mac(mac(online: true, seen: 0)).recordName == "mac-A")
}

@Test("Tests are answered oldest first, once, and dropped past ten minutes")
func pingTriage() {
  let old = CompanionPing(nonce: "old", deviceName: "iPhone", sentAt: now.addingTimeInterval(-601))
  let second = CompanionPing(nonce: "b", deviceName: "iPhone", sentAt: now.addingTimeInterval(-5))
  let first = CompanionPing(nonce: "a", deviceName: "iPhone", sentAt: now.addingTimeInterval(-9))
  let done = CompanionPing(nonce: "done", deviceName: "iPhone", sentAt: now)

  let triage = CompanionInbox.triage([second, old, done, first], handled: ["done"], now: now)

  #expect(triage.toAnswer == [first, second])
  #expect(triage.expired == [old])
}

@Test("A snapshot writes only what changed, and deletes the sessions no longer active")
func sessionMerge() {
  let earlier = now.addingTimeInterval(-300)
  let unchanged = CompanionSession(
    id: "1", macID: "A", title: "Toolbar", agent: "Codex", state: .working, updatedAt: earlier)
  let changing = CompanionSession(
    id: "2", macID: "A", title: "Notes", agent: "Claude Code", state: .working, updatedAt: earlier)
  let gone = CompanionSession(
    id: "3", macID: "A", title: "Old", agent: "Codex", state: .waiting, updatedAt: earlier)
  let otherMac = CompanionSession(
    id: "4", macID: "B", title: "Elsewhere", agent: "Codex", state: .waiting, updatedAt: earlier)

  let plan = CompanionSessionMerge.plan(
    snapshot: [
      unchanged.info,
      CompanionSessionInfo(id: "2", title: "Notes", agent: "Claude Code", state: .needsAttention),
      CompanionSessionInfo(id: "5", title: "New", agent: "Codex", state: .waiting),
    ],
    stored: [unchanged, changing, gone, otherMac], macID: "A", now: now)

  #expect(plan.saves.map(\.id) == ["2", "5"])
  #expect(plan.saves.allSatisfy { $0.updatedAt == now && $0.macID == "A" })
  #expect(plan.saves.first?.state == .needsAttention)
  #expect(plan.deletions == ["session-3"])
}

@Test("An empty snapshot clears every session of this Mac, and only those")
func emptySnapshotClearsTheMac() {
  let stored = [
    CompanionSession(id: "1", macID: "A", title: "x", agent: "y", state: .working, updatedAt: now),
    CompanionSession(id: "2", macID: "B", title: "x", agent: "y", state: .working, updatedAt: now),
  ]
  let plan = CompanionSessionMerge.plan(snapshot: [], stored: stored, macID: "A", now: now)
  #expect(plan.saves.isEmpty)
  #expect(plan.deletions == ["session-1"])
}

@Test("A test goes from sending to sent to acknowledged, with its delays")
func testRunStages() {
  var run = CompanionTestRun(nonce: "7F3A", sentAt: now)
  #expect(run.stage == .sending)
  run.markSent()
  #expect(run.stage == .sent)

  let stranger = CompanionPong(nonce: "other", macID: "A", receivedAt: now)
  let tookStranger = run.acknowledge(stranger, at: now.addingTimeInterval(2))
  #expect(!tookStranger)
  #expect(run.stage == .sent)

  let pong = CompanionPong(nonce: "7F3A", macID: "A", receivedAt: now.addingTimeInterval(2))
  let tookPong = run.acknowledge(pong, at: now.addingTimeInterval(4))
  #expect(tookPong)
  #expect(run.stage == .acknowledged)
  #expect(run.oneWay == 2)
  #expect(run.roundTrip == 4)

  // A late confirmation of the ping's save does not undo the acknowledgement.
  run.markSent()
  #expect(run.stage == .acknowledged)
  let tookTwice = run.acknowledge(pong, at: now.addingTimeInterval(9))
  #expect(!tookTwice)
  #expect(run.roundTrip == 4)
}
