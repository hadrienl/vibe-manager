import CloudKit
import CompanionCore
import Foundation
import Testing

@testable import CompanionKit

@Test("A frame is sixteen big-endian bytes, and comes back as it left")
func echoFrameRoundTrip() throws {
  let frame = CompanionEchoFrame(sequence: 0x0102_0304_0506_0708, sentAt: UInt64.max - 1)
  let data = frame.encoded
  #expect(data.count == CompanionEchoFrame.size)
  #expect(Array(data.prefix(8)) == [1, 2, 3, 4, 5, 6, 7, 8])
  #expect(CompanionEchoFrame(decoding: data) == frame)
}

@Test("Anything but sixteen bytes is no frame")
func echoFrameRejectsOtherSizes() {
  #expect(CompanionEchoFrame(decoding: Data()) == nil)
  #expect(CompanionEchoFrame(decoding: Data(count: 15)) == nil)
  #expect(CompanionEchoFrame(decoding: Data(count: 17)) == nil)
}

@Test("The round trip is read on the phone's clock, in milliseconds, never negative")
func echoRoundTrip() {
  let frame = CompanionEchoFrame(sequence: 1, sentAt: 5_000_000_000)
  #expect(frame.roundTrip(receivedAt: 5_042_500_000) == 42.5)
  #expect(frame.roundTrip(receivedAt: 4_000_000_000) == nil)
}

@Test("Percentiles go by nearest rank over the window")
func roundTripPercentiles() {
  var trips = CompanionRoundTrips(capacity: 100)
  #expect(trips.p50 == nil && trips.last == nil)
  for value in (1...100).reversed() { trips.add(Double(value)) }
  #expect(trips.last == 1)
  #expect(trips.p50 == 50)
  #expect(trips.p95 == 95)
  #expect(trips.percentile(1) == 100)
  #expect(trips.percentile(0) == 1)

  var one = CompanionRoundTrips()
  one.add(12)
  #expect(one.p50 == 12 && one.p95 == 12)
}

@Test("The window keeps only the last round trips")
func roundTripWindow() {
  var trips = CompanionRoundTrips(capacity: 3)
  for value in [500.0, 10, 20, 30] { trips.add(value) }
  #expect(trips.recent == [10, 20, 30])
  #expect(trips.p95 == 30)
}

@Test("The selected path says direct or relay; none selected is unknown")
func selectedPath() {
  #expect(CompanionPathKind.selected(among: []) == .unknown)
  #expect(CompanionPathKind.selected(among: [(false, true), (false, false)]) == .unknown)
  #expect(CompanionPathKind.selected(among: [(false, true), (true, false)]) == .direct)
  #expect(CompanionPathKind.selected(among: [(true, true), (false, false)]) == .relay)
}

@Test("The relay's share counts the time on a known path, with the channel open")
func relayShare() throws {
  var ledger = CompanionPathLedger()
  #expect(ledger.relayShare(at: 0) == nil)
  ledger.note(.unknown, at: 0)
  ledger.note(.relay, at: 1)  // one second unknown: counted for neither
  ledger.note(.direct, at: 3)  // two seconds relayed
  #expect(ledger.relayShare(at: 9) == 0.25)  // then six direct
  ledger.note(nil, at: 9)  // channel closed: ten seconds that count for nothing
  ledger.note(.direct, at: 19)
  #expect(ledger.relayShare(at: 21) == 0.2)
  #expect(ledger.current == .direct)
}

@Test("A switch is between direct and relay, whatever lies between")
func pathSwitches() {
  var ledger = CompanionPathLedger()
  ledger.note(.relay, at: 0)
  ledger.note(.relay, at: 1)
  #expect(ledger.switches == 0)
  ledger.note(.direct, at: 2)
  ledger.note(.unknown, at: 3)
  ledger.note(.direct, at: 4)
  #expect(ledger.switches == 1)
  ledger.note(nil, at: 5)
  ledger.note(.relay, at: 6)
  #expect(ledger.switches == 2)
}

@Test("The export has a header and one line a sample, in milliseconds")
func echoCSV() {
  let date = Date(timeIntervalSince1970: 1_800_000_000.25)
  let samples = [
    CompanionEchoSample(
      date: date, session: 1, sequence: 7, roundTrip: 42.5, path: .direct, setup: 812.25),
    CompanionEchoSample(
      date: date, session: 2, sequence: 0, roundTrip: 3, path: .relay, setup: nil),
  ]
  let lines = CompanionEchoCSV.text(samples).split(separator: "\n").map(String.init)
  #expect(lines.count == 3)
  #expect(lines[0] == "date,session,sequence,rtt_ms,path,setup_ms")
  #expect(lines[1] == "2027-01-15T08:00:00.250Z,1,7,42.500,direct,812.250")
  #expect(lines[2] == "2027-01-15T08:00:00.250Z,2,0,3.000,relay,")
}

@Test("The Mac's iroh address travels encrypted in its record, and is optional")
func macIrohFields() throws {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let mac = CompanionMac(
    installationID: "A1", name: "MacBook", version: "1.0.2", buildLabel: "", online: true,
    lastSeen: now, irohEndpointID: "ae58ff88", irohRelayURL: "https://euc1-1.relay.n0.iroh.link./")
  let record = CompanionRecordCodec.makeRecord(.mac(mac), systemFields: nil)
  #expect(record["irohEndpointID"] == nil)
  #expect(record.encryptedValues["irohEndpointID"] as? String == "ae58ff88")
  #expect(CompanionRecordCodec.decode(record) == .mac(mac))

  var bare = mac
  bare.irohEndpointID = nil
  bare.irohRelayURL = nil
  let old = CompanionRecordCodec.makeRecord(.mac(bare), systemFields: nil)
  #expect(CompanionRecordCodec.decode(old) == .mac(bare))
}
