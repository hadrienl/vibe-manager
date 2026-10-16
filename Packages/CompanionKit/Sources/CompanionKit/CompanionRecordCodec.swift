import CloudKit
import CompanionCore
import Foundation

/// Where the companion's records live in iCloud (#347).
public enum CompanionCloud {
  /// The same in the iOS application and in the Mac's companion agent: both entitlements name it.
  /// Created on 2026-10-10, and final: a container can be neither deleted nor renamed.
  public static let containerIdentifier = "iCloud.eu.hadrien.VibeManager"
  public static let zoneID = CKRecordZone.ID(
    zoneName: "Companion", ownerName: CKCurrentUserDefaultName)

  public static func recordID(_ name: String) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zoneID)
  }
}

/// A companion record to a `CKRecord` and back.
///
/// Titles, names and states are in `encryptedValues`, end to end encrypted by Apple: only the Mac's
/// identifier, the nonces and the dates are in the clear. An encrypted field can be neither indexed
/// nor queried, which the sync engine never does. A field once written encrypted must stay so: the
/// same key written in the clear would be another field.
public enum CompanionRecordCodec {
  public enum RecordType {
    public static let mac = "Mac"
    public static let session = "Session"
    public static let ping = "Ping"
    public static let pong = "Pong"
    public static let request = "Request"
  }

  enum Field {
    static let name = "name"
    static let version = "version"
    static let buildLabel = "buildLabel"
    static let online = "online"
    static let lastSeen = "lastSeen"
    static let macID = "macID"
    static let title = "title"
    static let agent = "agent"
    static let state = "state"
    static let updatedAt = "updatedAt"
    static let deviceName = "deviceName"
    static let sentAt = "sentAt"
    static let nonce = "nonce"
    static let receivedAt = "receivedAt"
    static let irohEndpointID = "irohEndpointID"
    static let irohRelayURL = "irohRelayURL"
    static let requestDelay = "requestDelay"
    static let sessionTitle = "sessionTitle"
    static let agentName = "agentName"
    static let text = "text"
    static let message = "message"
    static let createdAt = "createdAt"
  }

  public static func recordType(of record: CompanionRecord) -> String {
    switch record {
    case .mac: RecordType.mac
    case .session: RecordType.session
    case .ping: RecordType.ping
    case .pong: RecordType.pong
    case .request: RecordType.request
    }
  }

  /// The record to send: on top of the system fields last saved or fetched, when there are any,
  /// so that CloudKit sees an update of the record it holds rather than a conflicting creation.
  public static func makeRecord(_ record: CompanionRecord, systemFields: Data?) -> CKRecord {
    let id = CompanionCloud.recordID(record.recordName)
    let type = recordType(of: record)
    let ckRecord =
      systemFields.flatMap(CKRecord.fromArchivedSystemFields).flatMap {
        $0.recordID == id && $0.recordType == type ? $0 : nil
      } ?? CKRecord(recordType: type, recordID: id)
    encode(record, into: ckRecord)
    return ckRecord
  }

  static func encode(_ record: CompanionRecord, into ckRecord: CKRecord) {
    let secret = ckRecord.encryptedValues
    switch record {
    case .mac(let mac):
      secret[Field.name] = mac.name
      secret[Field.version] = mac.version
      secret[Field.buildLabel] = mac.buildLabel
      secret[Field.online] = mac.online
      ckRecord[Field.lastSeen] = mac.lastSeen
      // Encrypted like the rest, though a public key: nothing reads them but the phone.
      secret[Field.irohEndpointID] = mac.irohEndpointID
      secret[Field.irohRelayURL] = mac.irohRelayURL
    case .session(let session):
      ckRecord[Field.macID] = session.macID
      secret[Field.title] = session.title
      secret[Field.agent] = session.agent
      secret[Field.state] = session.state.rawValue
      ckRecord[Field.updatedAt] = session.updatedAt
    case .ping(let ping):
      ckRecord[Field.nonce] = ping.nonce
      secret[Field.deviceName] = ping.deviceName
      ckRecord[Field.sentAt] = ping.sentAt
      ckRecord[Field.requestDelay] = ping.requestDelay
    case .pong(let pong):
      ckRecord[Field.nonce] = pong.nonce
      ckRecord[Field.macID] = pong.macID
      ckRecord[Field.receivedAt] = pong.receivedAt
    case .request(let request):
      // Encrypted, read by the phone's notification service extension rather than by CloudKit's
      // servers. Under new names: `sessionTitle`, `agentName` and `text` were first written in the
      // clear (#368), and a field keeps the kind it was first written with.
      ckRecord[Field.macID] = request.macID
      secret[Field.title] = request.sessionTitle
      secret[Field.agent] = request.agent
      secret[Field.message] = request.text
      ckRecord[Field.createdAt] = request.createdAt
    }
  }

  /// `nil` for a record of another type, of another zone, or missing a field: a later version may
  /// write what this one does not read, and that is not this one's to show.
  public static func decode(_ ckRecord: CKRecord) -> CompanionRecord? {
    guard ckRecord.recordID.zoneID == CompanionCloud.zoneID else { return nil }
    let name = ckRecord.recordID.recordName
    let secret = ckRecord.encryptedValues
    switch ckRecord.recordType {
    case RecordType.mac:
      guard let id = name.dropPrefix("mac-"),
        let macName = secret[Field.name] as? String,
        let lastSeen = ckRecord[Field.lastSeen] as? Date
      else { return nil }
      return .mac(
        CompanionMac(
          installationID: id, name: macName, version: secret[Field.version] as? String ?? "",
          buildLabel: secret[Field.buildLabel] as? String ?? "",
          online: secret[Field.online] as? Bool ?? false, lastSeen: lastSeen,
          irohEndpointID: secret[Field.irohEndpointID] as? String,
          irohRelayURL: secret[Field.irohRelayURL] as? String))
    case RecordType.session:
      guard let id = name.dropPrefix("session-"),
        let macID = ckRecord[Field.macID] as? String,
        let title = secret[Field.title] as? String,
        let updatedAt = ckRecord[Field.updatedAt] as? Date
      else { return nil }
      return .session(
        CompanionSession(
          id: id, macID: macID, title: title, agent: secret[Field.agent] as? String ?? "",
          state: (secret[Field.state] as? String).flatMap(CompanionSessionState.init(rawValue:))
            ?? .waiting,
          updatedAt: updatedAt))
    case RecordType.ping:
      guard let nonce = ckRecord[Field.nonce] as? String,
        let sentAt = ckRecord[Field.sentAt] as? Date
      else { return nil }
      return .ping(
        CompanionPing(
          nonce: nonce, deviceName: secret[Field.deviceName] as? String ?? "", sentAt: sentAt,
          requestDelay: ckRecord[Field.requestDelay] as? Double))
    case RecordType.pong:
      guard let nonce = ckRecord[Field.nonce] as? String,
        let macID = ckRecord[Field.macID] as? String,
        let receivedAt = ckRecord[Field.receivedAt] as? Date
      else { return nil }
      return .pong(CompanionPong(nonce: nonce, macID: macID, receivedAt: receivedAt))
    case RecordType.request:
      guard let id = name.dropPrefix("request-"),
        let macID = ckRecord[Field.macID] as? String,
        let createdAt = ckRecord[Field.createdAt] as? Date
      else { return nil }
      // The fields in the clear are those of the first requests (#368), still in the zone for
      // their hour.
      return .request(
        CompanionRequest(
          id: id, macID: macID,
          sessionTitle: secret[Field.title] as? String ?? ckRecord[Field.sessionTitle] as? String
            ?? "",
          agent: secret[Field.agent] as? String ?? ckRecord[Field.agentName] as? String ?? "",
          text: secret[Field.message] as? String ?? ckRecord[Field.text] as? String ?? "",
          createdAt: createdAt))
    default:
      return nil
    }
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

extension String {
  fileprivate func dropPrefix(_ prefix: String) -> String? {
    guard hasPrefix(prefix), count > prefix.count else { return nil }
    return String(dropFirst(prefix.count))
  }
}
