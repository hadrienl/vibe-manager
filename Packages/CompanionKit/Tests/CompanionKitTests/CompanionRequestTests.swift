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

@Test("A request's texts are encrypted, and come back from its record as they were")
func requestRecord() throws {
  let request = CompanionRequest(
    id: "R1", macID: "A1", sessionTitle: "#368 Notifications", agent: "Codex",
    text: "attend votre réponse", createdAt: now)
  let ckRecord = CompanionRecordCodec.makeRecord(.request(request), systemFields: nil)
  #expect(ckRecord.recordType == "Request")
  for key in ["title", "agent", "message"] {
    #expect(ckRecord[key] == nil, "\(key) in the clear")
    #expect(ckRecord.encryptedValues[key] != nil, "\(key) not encrypted")
  }
  // Nothing under the names of the first requests, which were in the clear.
  for key in ["sessionTitle", "agentName", "text"] {
    #expect(ckRecord[key] == nil && ckRecord.encryptedValues[key] == nil, "\(key) written")
  }
  #expect(ckRecord.encryptedValues["title"] as? String == "#368 Notifications")
  #expect(ckRecord["macID"] as? String == "A1")
  #expect(ckRecord["createdAt"] as? Date == now)
  #expect(CompanionRecordCodec.decode(ckRecord) == .request(request))

  let ping = CompanionPing(nonce: "7F3A", deviceName: "iPhone", sentAt: now, requestDelay: 10)
  let pingRecord = CompanionRecordCodec.makeRecord(.ping(ping), systemFields: nil)
  #expect(CompanionRecordCodec.decode(pingRecord) == .ping(ping))
}

@Test("A request of the first version, in the clear, is still read")
func clearRequestRecord() {
  let ckRecord = CKRecord(recordType: "Request", recordID: CompanionCloud.recordID("request-R0"))
  ckRecord["macID"] = "A1"
  ckRecord["sessionTitle"] = "Ancienne"
  ckRecord["agentName"] = "Claude Code"
  ckRecord["text"] = "attend votre réponse"
  ckRecord["createdAt"] = now
  #expect(
    CompanionRecordCodec.decode(ckRecord)
      == .request(
        CompanionRequest(
          id: "R0", macID: "A1", sessionTitle: "Ancienne", agent: "Claude Code",
          text: "attend votre réponse", createdAt: now)))
}

@Test("The subscription pushes a generic, mutable alert on each new request of the zone")
func requestSubscription() {
  let subscription = CompanionRequestAlerts.subscription()
  #expect(subscription.subscriptionID == "companion-requests-v2")
  #expect(CompanionRequestAlerts.retiredSubscriptionIDs == ["companion-requests-v1"])
  #expect(subscription.recordType == "Request")
  #expect(subscription.zoneID == CompanionCloud.zoneID)
  #expect(subscription.querySubscriptionOptions == [.firesOnRecordCreation])
  let info = subscription.notificationInfo
  #expect(info?.titleLocalizationKey == CompanionRequestAlerts.LocalizationKey.title)
  #expect(info?.alertLocalizationKey == CompanionRequestAlerts.LocalizationKey.body)
  // Nothing of the record in the push: no argument, no desired key.
  #expect(info?.titleLocalizationArgs?.isEmpty ?? true)
  #expect(info?.alertLocalizationArgs?.isEmpty ?? true)
  #expect(info?.desiredKeys?.isEmpty ?? true)
  #expect(info?.shouldSendMutableContent == true)
  #expect(info?.soundName == "default")
  #expect(info?.shouldBadge == true)
  #expect(info?.shouldSendContentAvailable == false)
}

@Test("The extension's alert names the session, then the agent and what it waits for")
func requestAlertText() throws {
  func request(_ title: String, _ agent: String, _ text: String) -> CompanionRequest {
    CompanionRequest(
      id: "R", macID: "A", sessionTitle: title, agent: agent, text: text, createdAt: now)
  }
  let alert = try #require(
    CompanionRequestAlerts.alert(
      for: request("#368 Notifications", "Codex", "attend votre réponse")))
  #expect(alert.title == "#368 Notifications")
  #expect(alert.body == "Codex attend votre réponse")

  let untitled = try #require(CompanionRequestAlerts.alert(for: request(" ", "Codex", "attend")))
  #expect(untitled.title.isEmpty)
  #expect(untitled.body == "Codex attend")
  #expect(CompanionRequestAlerts.alert(for: request("Session", "", "attend"))?.body == "attend")
  #expect(CompanionRequestAlerts.alert(for: request("", "", "")) == nil)
}

@Test("Only a push of the subscription, about the companion's zone, names a request")
func requestPushRecordID() {
  func push(subscription: String, zone: String = "Companion") -> [AnyHashable: Any] {
    [
      "aps": ["alert": ["loc-key": "COMPANION_REQUEST_ALERT_BODY"], "mutable-content": 1],
      "ck": [
        "ce": 2, "cid": "iCloud.eu.hadrien.VibeManager.Debug", "nid": "N1",
        "qry": [
          "dbs": 2, "fo": 1, "rid": "request-R1", "sid": subscription, "zid": zone,
          "zoid": "_defaultOwner",
        ],
      ],
    ]
  }
  let id = CompanionRequestAlerts.recordID(fromPush: push(subscription: "companion-requests-v2"))
  #expect(id?.recordName == "request-R1")
  #expect(id?.zoneID == CompanionCloud.zoneID)
  #expect(
    CompanionRequestAlerts.recordID(fromPush: push(subscription: "companion-requests-v1")) == nil)
  #expect(
    CompanionRequestAlerts.recordID(
      fromPush: push(subscription: "companion-requests-v2", zone: "Other")) == nil)
  #expect(CompanionRequestAlerts.recordID(fromPush: ["aps": ["alert": "x"]]) == nil)
}
