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
]

@Test("Every record comes back from its CKRecord as it was", arguments: records)
func roundTrip(record: CompanionRecord) throws {
  let ckRecord = CompanionRecordCodec.makeRecord(record, systemFields: nil)
  #expect(ckRecord.recordID.zoneID == CompanionCloud.zoneID)
  #expect(ckRecord.recordID.recordName == record.recordName)
  #expect(CompanionRecordCodec.decode(ckRecord) == record)
}

@Test("Titles, names and states are encrypted; only identifiers and dates are in the clear")
func encryptedFields() throws {
  let mac = CompanionRecordCodec.makeRecord(records[0], systemFields: nil)
  for key in ["name", "version", "buildLabel", "online"] {
    #expect(mac[key] == nil, "\(key) in the clear")
    #expect(mac.encryptedValues[key] != nil, "\(key) not encrypted")
  }
  #expect(mac["lastSeen"] as? Date == now)

  let session = CompanionRecordCodec.makeRecord(records[1], systemFields: nil)
  for key in ["title", "agent", "state"] {
    #expect(session[key] == nil, "\(key) in the clear")
    #expect(session.encryptedValues[key] != nil, "\(key) not encrypted")
  }
  #expect(session["macID"] as? String == "A1")
  #expect(session.encryptedValues["title"] as? String == "#347 Compagnon mobile")

  let ping = CompanionRecordCodec.makeRecord(records[2], systemFields: nil)
  #expect(ping["deviceName"] == nil)
  #expect(ping.encryptedValues["deviceName"] as? String == "iPhone de Hadrien")
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
  #expect(ping.recordType == "Ping")
}

@Test("A record of another zone, another type or missing a field is not read")
func unreadableRecords() {
  let elsewhere = CKRecord(
    recordType: "Session",
    recordID: CKRecord.ID(recordName: "session-1", zoneID: CKRecordZone.ID(zoneName: "Other")))
  #expect(CompanionRecordCodec.decode(elsewhere) == nil)

  let unknown = CKRecord(recordType: "Message", recordID: CompanionCloud.recordID("message-1"))
  #expect(CompanionRecordCodec.decode(unknown) == nil)

  let incomplete = CKRecord(recordType: "Session", recordID: CompanionCloud.recordID("session-1"))
  incomplete["macID"] = "A1"
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
