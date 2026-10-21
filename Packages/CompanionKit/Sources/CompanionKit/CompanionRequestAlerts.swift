import CloudKit
import CompanionCore
import Foundation
import os

/// The visible notification of a request (#368): a subscription the phone saves once, on which
/// CloudKit's servers push an alert — title, text, sound, badge — at every request the Mac
/// creates: an `Envelope` record of kind `request`, the field the subscription filters on (#396).
/// Visible pushes are not rationed as silent ones are, and reach a locked phone or an application
/// in the background.
///
/// The alert CloudKit pushes says nothing of the request — « Un agent attend votre réponse » — and
/// is mutable: the phone's notification service extension fetches the record, whose texts are
/// encrypted, and writes the session and the agent in it before iOS shows it. Nothing readable of
/// a session goes through Apple's push servers; if the extension cannot read the record in time,
/// the generic alert is shown as it came.
///
/// A query subscription, bound to the companion's zone of the private database, which CloudKit
/// supports for query subscriptions in the private and public databases, never the shared one.
public enum CompanionRequestAlerts {
  /// Fixed, so that saving it again replaces it rather than adding another. A change of what the
  /// subscription says takes a new identifier, the old one deleted.
  public static let subscriptionID = "companion-requests-v3"
  /// The earlier ones — the first made its alert of fields in the clear, the second watched the
  /// `Request` type of the trials (#368): deleted when this one is saved, or a phone that had one
  /// would show two alerts per request.
  static let retiredSubscriptionIDs = ["companion-requests-v1", "companion-requests-v2"]

  /// The keys of the phone's `Localizable.strings`, in the application and in its extension.
  public enum LocalizationKey {
    /// « Vibe Manager ».
    public static let title = "COMPANION_REQUEST_ALERT_TITLE"
    /// « Un agent attend votre réponse ».
    public static let body = "COMPANION_REQUEST_ALERT_BODY"
  }

  private static let logger = Logger(
    subsystem: "eu.hadrien.VibeManager.companion", category: "notify")

  /// The subscription, as saved: built offline, for the tests to read.
  public static func subscription() -> CKQuerySubscription {
    let subscription = CKQuerySubscription(
      recordType: CompanionRecordCodec.RecordType.envelope,
      predicate: NSPredicate(format: "kind == %@", CompanionRecordCodec.Kind.request),
      subscriptionID: subscriptionID, options: [.firesOnRecordCreation])
    subscription.zoneID = CompanionCloud.zoneID
    let info = CKSubscription.NotificationInfo()
    info.titleLocalizationKey = LocalizationKey.title
    info.alertLocalizationKey = LocalizationKey.body
    info.soundName = "default"
    info.shouldBadge = true
    // For the notification service extension to run, and replace the texts.
    info.shouldSendMutableContent = true
    // Visible, not silent: the silent ones are the sync engine's, through its own subscription.
    info.shouldSendContentAvailable = false
    subscription.notificationInfo = info
    return subscription
  }

  /// What the extension writes in the alert: the session as its title, what the agent waits for
  /// as its text, in the phone's language — `phrase` makes it of the agent's name and the request's
  /// code (`CompanionRequests.waitingText`, `testText`). `nil` for a request with nothing to show:
  /// the generic alert says more.
  public static func alert(
    for request: CompanionRequest, phrase: (_ agent: String, _ code: String) -> String
  ) -> (title: String, body: String)? {
    let title = request.sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = phrase(
      request.agent.trimmingCharacters(in: .whitespacesAndNewlines),
      request.text.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !title.isEmpty || !body.isEmpty else { return nil }
    return (title, body)
  }

  /// The record a push of the subscription is about, or `nil` for any other push.
  ///
  /// Named in the companion's zone as the codec names it, by the zone's name alone: the push may
  /// give the zone's owner by the user's record name rather than `CKCurrentUserDefaultName`, and the
  /// codec reads no record of a zone it does not recognise.
  public static func recordID(fromPush userInfo: [AnyHashable: Any]) -> CKRecord.ID? {
    guard
      let notification = CKNotification(fromRemoteNotificationDictionary: userInfo)
        as? CKQueryNotification,
      notification.subscriptionID == subscriptionID,
      let recordID = notification.recordID,
      recordID.zoneID.zoneName == CompanionCloud.zoneID.zoneName
    else { return nil }
    return CompanionCloud.recordID(recordID.recordName)
  }

  /// The request a push is about, fetched from the private database and decrypted.
  public static func fetchRequest(
    _ recordID: CKRecord.ID, containerIdentifier: String = CompanionCloud.containerIdentifier
  ) async throws -> CompanionRequest? {
    let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    let record = try await database.record(for: recordID)
    guard case .request(let request)? = CompanionRecordCodec.decode(record) else { return nil }
    return request
  }

  /// Saves the subscription unless the database already has it: one request at each launch.
  ///
  /// Fails with `invalidArguments` — "did not find record type" — until the Mac wrote a first
  /// `Request`: in the Development environment the schema is made by the first write, and a
  /// subscription cannot name a type that does not exist yet. The caller asks again later.
  public static func save(containerIdentifier: String = CompanionCloud.containerIdentifier)
    async throws
  {
    let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    do {
      _ = try await database.subscription(for: subscriptionID)
      logger.notice("subscription: already saved")
      return
    } catch let error as CKError where error.code == .unknownItem {
      // Not there yet: saved below.
    }
    let results = try await database.modifySubscriptions(
      saving: [subscription()], deleting: [])
    if case .failure(let error)? = results.saveResults[subscriptionID] {
      logger.error(
        "subscription: not saved: \(CompanionErrorText.describe(error), privacy: .public)")
      throw error
    }
    logger.notice("subscription: saved")
    await deleteRetired(from: database)
  }

  /// Apart from the save: a subscription already gone answers `unknownItem`, which must not fail
  /// it. Not tried again — the new one is saved once, the old one only lives on a phone that had it.
  private static func deleteRetired(from database: CKDatabase) async {
    do {
      let results = try await database.modifySubscriptions(
        saving: [], deleting: retiredSubscriptionIDs)
      for (id, result) in results.deleteResults {
        switch result {
        case .success:
          logger.notice("subscription: \(id, privacy: .public) deleted")
        case .failure(let error as CKError) where error.code == .unknownItem:
          break
        case .failure(let error):
          logger.error(
            "subscription: \(id, privacy: .public) not deleted: \(CompanionErrorText.describe(error), privacy: .public)"
          )
        }
      }
    } catch {
      logger.error(
        "subscription: retired ones not deleted: \(CompanionErrorText.describe(error), privacy: .public)"
      )
    }
  }
}
