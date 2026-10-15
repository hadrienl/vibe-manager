import CloudKit
import CompanionCore
import Foundation
import os

/// The visible notification of a request (#368): a subscription the phone saves once, on which
/// CloudKit's servers push an alert — title, text, sound, badge — at every `Request` record the
/// Mac creates. Visible pushes are not rationed as silent ones are, and reach a locked phone or an
/// application in the background; the phone's code does not run for them.
///
/// A query subscription rather than the zone's: only a query subscription builds its alert from
/// the record's fields (`titleLocalizationArgs`, `alertLocalizationArgs`). It is bound to the
/// companion's zone of the private database, which CloudKit supports for query subscriptions in
/// the private and public databases, never the shared one.
public enum CompanionRequestAlerts {
  /// Fixed, so that saving it again replaces it rather than adding another. A change of what the
  /// subscription says takes a new identifier, the old one deleted.
  public static let subscriptionID = "companion-requests-v1"

  /// The keys of the phone's `Localizable.strings`: iOS formats them with the record's fields.
  public enum LocalizationKey {
    /// `%1$@`: the session's title.
    public static let title = "COMPANION_REQUEST_TITLE"
    /// `%1$@ %2$@`: the agent's name, then what it waits for.
    public static let body = "COMPANION_REQUEST_BODY"
  }

  private static let logger = Logger(
    subsystem: "eu.hadrien.VibeManager.companion", category: "notify")

  /// The subscription, as saved: built offline, for the tests to read.
  public static func subscription() -> CKQuerySubscription {
    let subscription = CKQuerySubscription(
      recordType: CompanionRecordCodec.RecordType.request, predicate: NSPredicate(value: true),
      subscriptionID: subscriptionID, options: [.firesOnRecordCreation])
    subscription.zoneID = CompanionCloud.zoneID
    let info = CKSubscription.NotificationInfo()
    info.titleLocalizationKey = LocalizationKey.title
    info.titleLocalizationArgs = [CompanionRecordCodec.RequestField.sessionTitle]
    info.alertLocalizationKey = LocalizationKey.body
    info.alertLocalizationArgs = [
      CompanionRecordCodec.RequestField.agentName, CompanionRecordCodec.RequestField.text,
    ]
    info.soundName = "default"
    info.shouldBadge = true
    // Visible, not silent: the silent ones are the sync engine's, through its own subscription.
    info.shouldSendContentAvailable = false
    subscription.notificationInfo = info
    return subscription
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
  }
}
