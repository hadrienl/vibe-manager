import CloudKit
import CompanionCore
import Foundation
import Testing

@testable import CompanionKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func info(_ id: String, _ state: CompanionSessionState) -> CompanionSessionInfo {
  CompanionSessionInfo(id: id, title: "Session \(id)", agent: "Claude Code", state: state)
}

@Test("A request comes once per entry into waiting for the user, never per snapshot")
func requestPerEntry() {
  let first = [info("1", .working), info("2", .needsAttention)]
  // The first snapshot is where the agent starts from: a session already waiting is not news.
  #expect(CompanionRequests.entered(previous: nil, current: first).isEmpty)

  let second = [info("1", .needsAttention), info("2", .needsAttention), info("3", .needsAttention)]
  #expect(CompanionRequests.entered(previous: first, current: second).map(\.id) == ["1", "3"])
  // Still waiting: nothing new.
  #expect(CompanionRequests.entered(previous: second, current: second).isEmpty)

  // Answered, then waiting again: a new entry, a new request.
  let third = [info("1", .working), info("2", .needsAttention), info("3", .needsAttention)]
  #expect(CompanionRequests.entered(previous: second, current: third).isEmpty)
  let fourth = [info("1", .needsAttention), info("2", .needsAttention), info("3", .waiting)]
  #expect(CompanionRequests.entered(previous: third, current: fourth).map(\.id) == ["1"])
}

@Test("A request names its session and its agent, a nameless agent included")
func requestContent() {
  let named = CompanionRequests.request(
    for: info("1", .needsAttention), macID: "A", id: "R1", now: now)
  #expect(named.sessionTitle == "Session 1")
  #expect(named.agent == "Claude Code")
  #expect(named.text == CompanionRequests.waitingText)
  #expect(CompanionRecord.request(named).recordName == "request-R1")

  let nameless = CompanionRequests.request(
    for: CompanionSessionInfo(id: "2", title: "x", agent: "", state: .needsAttention),
    macID: "A", id: "R2", now: now)
  #expect(nameless.agent == CompanionRequests.unnamedAgent)
}

@Test("Requests are deleted past an hour, by the Mac that wrote them only")
func requestPurge() {
  func request(_ id: String, mac: String, age: TimeInterval) -> CompanionRequest {
    CompanionRequest(
      id: id, macID: mac, sessionTitle: "x", agent: "y", text: "z",
      createdAt: now.addingTimeInterval(-age))
  }
  let requests = [
    request("fresh", mac: "A", age: 59 * 60),
    request("old", mac: "A", age: 61 * 60),
    request("elsewhere", mac: "B", age: 3 * 60 * 60),
  ]
  #expect(CompanionRequests.expired(requests, macID: "A", now: now) == ["request-old"])
}

@Test("A test of the notifications goes to the agent, never to the application")
func notificationTestTriage() {
  let plain = CompanionPing(nonce: "a", deviceName: "iPhone", sentAt: now.addingTimeInterval(-3))
  let notify = CompanionPing(
    nonce: "b", deviceName: "iPhone", sentAt: now.addingTimeInterval(-2), requestDelay: 10)
  let triage = CompanionInbox.triage([notify, plain], handled: [], now: now)
  #expect(triage.toAnswer == [plain])
  #expect(triage.toNotify == [notify])
  #expect(triage.expired.isEmpty)
  #expect(CompanionInbox.triage([notify], handled: ["b"], now: now).toNotify.isEmpty)
}

@Test("A request is in the clear, for CloudKit to build the notification from it")
func requestRecord() throws {
  let request = CompanionRequest(
    id: "R1", macID: "A1", sessionTitle: "#368 Notifications", agent: "Codex",
    text: "attend votre réponse", createdAt: now)
  let ckRecord = CompanionRecordCodec.makeRecord(.request(request), systemFields: nil)
  #expect(ckRecord.recordType == "Request")
  #expect(ckRecord["sessionTitle"] as? String == "#368 Notifications")
  #expect(ckRecord["agentName"] as? String == "Codex")
  #expect(ckRecord["text"] as? String == "attend votre réponse")
  #expect(CompanionRecordCodec.decode(ckRecord) == .request(request))

  let ping = CompanionPing(nonce: "7F3A", deviceName: "iPhone", sentAt: now, requestDelay: 10)
  let pingRecord = CompanionRecordCodec.makeRecord(.ping(ping), systemFields: nil)
  #expect(CompanionRecordCodec.decode(pingRecord) == .ping(ping))
}

@Test("The subscription alerts on each new request of the zone, with the record's own words")
func requestSubscription() {
  let subscription = CompanionRequestAlerts.subscription()
  #expect(subscription.subscriptionID == CompanionRequestAlerts.subscriptionID)
  #expect(subscription.recordType == "Request")
  #expect(subscription.zoneID == CompanionCloud.zoneID)
  #expect(subscription.querySubscriptionOptions == [.firesOnRecordCreation])
  let info = subscription.notificationInfo
  #expect(info?.titleLocalizationArgs == ["sessionTitle"])
  #expect(info?.alertLocalizationArgs == ["agentName", "text"])
  #expect(info?.soundName == "default")
  #expect(info?.shouldSendContentAvailable == false)
}
