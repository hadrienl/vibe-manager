import CloudKit
import CompanionCore
import Foundation
import Testing

@testable import CompanionKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private let records: [CompanionRecord] = [
  .mac(
    CompanionMac(
      installationID: "A1", name: "MacBook Pro de Hadrien", version: "1.0.2",
      buildLabel: "#347 abc1234", online: true, lastSeen: now)),
  .session(
    CompanionSession(
      id: "6F1C", macID: "A1", title: "#347 Compagnon mobile", agent: "Claude Code",
      state: .needsAttention, updatedAt: now)),
  .ping(CompanionPing(nonce: "7F3A", deviceName: "iPhone de Hadrien", sentAt: now)),
  .pong(CompanionPong(nonce: "7F3A", macID: "A1", receivedAt: now.addingTimeInterval(2))),
  .request(
    CompanionRequest(
      id: "R1", macID: "A1", sessionTitle: "#401 Notifications", agent: "Claude Code",
      text: "waiting", createdAt: now, sessionID: "6F1C",
      detail: CompanionRequestDetail(
        requestID: "K", kind: .permission, title: "", subject: "git push"))),
  .answer(
    CompanionAnswer(
      id: "N1", macID: "A1", sessionID: "6F1C", requestID: "K", choice: .deny, createdAt: now)),
]

@Test("A request of the version before #401 is read, without its detail")
func requestBeforeDetail() throws {
  let json =
    #"{"v":1,"body":{"id":"R0","macID":"A1","sessionTitle":"T","agent":"Codex","#
    + #""text":"waiting","createdAt":0}}"#
  let ckRecord = CKRecord(
    recordType: "Envelope", recordID: CompanionCloud.recordID("request-R0"))
  ckRecord["kind"] = "request"
  ckRecord.encryptedValues["payload"] = Data(json.utf8)
  guard case .request(let request)? = CompanionRecordCodec.decode(ckRecord) else {
    Issue.record("not read")
    return
  }
  #expect(request.sessionID == nil)
  #expect(request.detail == nil)
}

@Test("Every record comes back from its CKRecord as it was", arguments: records)
func roundTrip(record: CompanionRecord) throws {
  let ckRecord = CompanionRecordCodec.makeRecord(record, systemFields: nil)
  #expect(ckRecord.recordID.zoneID == CompanionCloud.zoneID)
  #expect(ckRecord.recordID.recordName == record.recordName)
  #expect(CompanionRecordCodec.decode(ckRecord) == record)
}

@Test("Every record is an Envelope: its kind in the clear, all else encrypted", arguments: records)
func envelope(record: CompanionRecord) throws {
  let ckRecord = CompanionRecordCodec.makeRecord(record, systemFields: nil)
  #expect(ckRecord.recordType == "Envelope")
  #expect(Set(ckRecord.allKeys()) == ["kind", "payload"])
  #expect(ckRecord["payload"] == nil)
  #expect(ckRecord["kind"] as? String == CompanionRecordCodec.kind(of: record))
  #expect(ckRecord.encryptedValues["payload"] is Data)
}

@Test("A record is rebuilt on its saved system fields, and only on its own")
func systemFieldsAreReused() throws {
  let first = CompanionRecordCodec.makeRecord(records[1], systemFields: nil)
  let fields = first.archivedSystemFields
  let again = CompanionRecordCodec.makeRecord(records[1], systemFields: fields)
  #expect(again.recordID == first.recordID)
  #expect(again.creationDate == first.creationDate)

  // The fields of another record are not worn by this one.
  let ping = CompanionRecordCodec.makeRecord(records[2], systemFields: fields)
  #expect(ping.recordID.recordName == "ping-7F3A")
  #expect(ping.creationDate == nil)
}

@Test("A record of another zone, type, kind, format or name is not read")
func unreadableRecords() throws {
  let session = CompanionRecordCodec.makeRecord(records[1], systemFields: nil)
  func copy(
    type: String = "Envelope", zone: CKRecordZone.ID = CompanionCloud.zoneID,
    name: String = "session-6F1C"
  ) -> CKRecord {
    let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zone))
    record["kind"] = session["kind"]
    record.encryptedValues["payload"] = session.encryptedValues["payload"]
    return record
  }
  #expect(CompanionRecordCodec.decode(copy()) == records[1])
  #expect(CompanionRecordCodec.decode(copy(zone: CKRecordZone.ID(zoneName: "Other"))) == nil)
  #expect(CompanionRecordCodec.decode(copy(type: "Session")) == nil)
  #expect(CompanionRecordCodec.decode(copy(name: "session-other")) == nil)

  let unknown = copy()
  unknown["kind"] = "message"
  #expect(CompanionRecordCodec.decode(unknown) == nil)

  let later = copy()
  let payload = try #require(session.encryptedValues["payload"] as? Data)
  var json = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
  json["v"] = CompanionRecordCodec.payloadVersion + 1
  later.encryptedValues["payload"] = try JSONSerialization.data(withJSONObject: json)
  #expect(CompanionRecordCodec.decode(later) == nil)

  let incomplete = copy()
  incomplete.encryptedValues["payload"] = Data(#"{"v":1,"body":{"id":"6F1C"}}"#.utf8)
  #expect(CompanionRecordCodec.decode(incomplete) == nil)
}

@Test("The journal keeps the last hundred lines, newest first, and copies as text")
func journal() {
  var journal = CompanionJournal()
  let start = Date(timeIntervalSince1970: 0)
  for index in 0..<120 {
    journal.record("line \(index)", at: start.addingTimeInterval(Double(index)))
  }
  #expect(journal.entries.count == 100)
  #expect(journal.entries.first?.text == "line 119")
  #expect(journal.entries.last?.text == "line 20")

  let utc = TimeZone(identifier: "UTC") ?? .current
  let text = CompanionJournal.text(Array(journal.entries.prefix(2)), timeZone: utc)
  #expect(text == "00:01:59 line 119\n00:01:58 line 118")
  #expect(CompanionJournal.summary(["Session", "Mac", "Session"]) == "1 Mac, 2 Session")
}

@Test("A CloudKit error is said by its code's name")
func errorText() {
  let error = CKError(.networkUnavailable)
  #expect(CompanionErrorText.describe(error).hasPrefix("networkUnavailable — "))
  #expect(CompanionErrorText.name(of: .quotaExceeded) == "quotaExceeded")
}
