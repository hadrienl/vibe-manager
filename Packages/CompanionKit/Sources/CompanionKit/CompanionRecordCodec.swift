import CloudKit
import CompanionCore
import Foundation

/// Where the companion's records live in iCloud (#347).
public enum CompanionCloud {
  /// The same in the iOS application and in the Mac's companion agent: both entitlements name it.
  /// The real one (#396), whose schema holds the `Envelope` type alone; the trials' records went
  /// to `iCloud.eu.hadrien.VibeManager.Debug` (#368), which stays unused.
  public static let containerIdentifier = "iCloud.eu.hadrien.VibeManager"
  public static let zoneID = CKRecordZone.ID(
    zoneName: "Companion", ownerName: CKCurrentUserDefaultName)

  public static func recordID(_ name: String) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zoneID)
  }
}

/// A companion record to a `CKRecord` and back (#396).
///
/// One record type alone, `Envelope`, whatever the record: a `kind` in the clear, which the
/// request subscription filters on, and a `payload` in `encryptedValues` — the record's value as
/// JSON, with the version of its format. A Production schema only grows, never changes; with one
/// neutral type, a new kind of record or a new field is the application's business and never a
/// schema to deploy. Nothing of a session, an agent or a message is readable by CloudKit's
/// servers, nor by Apple's push service.
public enum CompanionRecordCodec {
  public enum RecordType {
    public static let envelope = "Envelope"
  }

  enum Field {
    static let kind = "kind"
    static let payload = "payload"
  }

  /// What a record is, in its `kind` field. A kind is never renamed: a version of the application
  /// reads the kinds it knows and skips the others.
  public enum Kind {
    public static let mac = "mac"
    public static let session = "session"
    public static let request = "request"
    /// The debug application's test (#347), in no build that ships.
    public static let ping = "ping"
    public static let pong = "pong"
  }

  /// The payload's format. A change a reader of the previous one cannot read raises it; a reader
  /// skips a payload of a later format, as written by a newer version.
  public static let payloadVersion = 1

  struct Payload<Body: Codable>: Codable {
    let v: Int
    let body: Body
  }

  public static func kind(of record: CompanionRecord) -> String {
    switch record {
    case .mac: Kind.mac
    case .session: Kind.session
    case .ping: Kind.ping
    case .pong: Kind.pong
    case .request: Kind.request
    }
  }

  /// The record to send: on top of the system fields last saved or fetched, when there are any,
  /// so that CloudKit sees an update of the record it holds rather than a conflicting creation.
  public static func makeRecord(_ record: CompanionRecord, systemFields: Data?) -> CKRecord {
    let id = CompanionCloud.recordID(record.recordName)
    let ckRecord =
      systemFields.flatMap(CKRecord.fromArchivedSystemFields).flatMap {
        $0.recordID == id && $0.recordType == RecordType.envelope ? $0 : nil
      } ?? CKRecord(recordType: RecordType.envelope, recordID: id)
    encode(record, into: ckRecord)
    return ckRecord
  }

  static func encode(_ record: CompanionRecord, into ckRecord: CKRecord) {
    ckRecord[Field.kind] = kind(of: record)
    ckRecord.encryptedValues[Field.payload] = payload(of: record)
  }

  static func payload(of record: CompanionRecord) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    // Plain values: their encoding cannot fail.
    return switch record {
    case .mac(let body): try! encoder.encode(Payload(v: payloadVersion, body: body))
    case .session(let body): try! encoder.encode(Payload(v: payloadVersion, body: body))
    case .ping(let body): try! encoder.encode(Payload(v: payloadVersion, body: body))
    case .pong(let body): try! encoder.encode(Payload(v: payloadVersion, body: body))
    case .request(let body): try! encoder.encode(Payload(v: payloadVersion, body: body))
    }
  }

  /// `nil` for a record of another type or zone, of a kind or format this version does not know,
  /// or that does not decode: a later version may write what this one does not read, and that is
  /// not this one's to show.
  public static func decode(_ ckRecord: CKRecord) -> CompanionRecord? {
    guard ckRecord.recordID.zoneID == CompanionCloud.zoneID,
      ckRecord.recordType == RecordType.envelope,
      let kind = ckRecord[Field.kind] as? String,
      let payload = ckRecord.encryptedValues[Field.payload] as? Data
    else { return nil }
    let record: CompanionRecord? =
      switch kind {
      case Kind.mac: body(CompanionMac.self, payload).map(CompanionRecord.mac)
      case Kind.session: body(CompanionSession.self, payload).map(CompanionRecord.session)
      case Kind.ping: body(CompanionPing.self, payload).map(CompanionRecord.ping)
      case Kind.pong: body(CompanionPong.self, payload).map(CompanionRecord.pong)
      case Kind.request: body(CompanionRequest.self, payload).map(CompanionRecord.request)
      default: nil
      }
    // The record's name is the one its value gives: anything else was not written by a companion.
    return record?.recordName == ckRecord.recordID.recordName ? record : nil
  }

  private static func body<Body: Codable>(_ type: Body.Type, _ payload: Data) -> Body? {
    guard let decoded = try? JSONDecoder().decode(Payload<Body>.self, from: payload),
      decoded.v <= payloadVersion
    else { return nil }
    return decoded.body
  }
}

extension CKRecord {
  /// The record's system fields alone — its identity and change tag — as kept between launches.
  public var archivedSystemFields: Data {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    encodeSystemFields(with: coder)
    coder.finishEncoding()
    return coder.encodedData
  }

  public static func fromArchivedSystemFields(_ data: Data) -> CKRecord? {
    guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    coder.requiresSecureCoding = true
    defer { coder.finishDecoding() }
    return CKRecord(coder: coder)
  }
}

