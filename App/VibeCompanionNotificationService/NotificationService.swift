import CompanionCore
import CompanionKit
import Foundation
import UserNotifications
import os

/// The notification service extension of Vibe Companion (#368): CloudKit pushes a generic alert at
/// each request of the Mac — « Un agent attend votre réponse » — and this fetches the request's
/// record, whose texts are encrypted, to write the session and the agent in it before iOS shows it.
///
/// Nothing readable of a session goes through Apple's push servers that way. Whatever goes wrong —
/// another push, no record, no network, no iCloud account, the time iOS gives running out — the
/// generic alert is shown as it came: a request is never lost for want of its words.
///
/// Small on purpose: an extension is killed past about 24 MB. CompanionKit only, for the codec and
/// the record's fetch; neither iroh nor the sync engine, which belong to the application.
final class NotificationService: UNNotificationServiceExtension {
  private static let logger = Logger(
    subsystem: "eu.hadrien.VibeManager.companion", category: "notify")

  /// The alert in the making, delivered once: by the fetch or by the time running out, whichever
  /// comes first, on threads of iOS's choosing.
  private let pending = PendingAlert()

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    let generic = PendingAlert.generic(request.content)
    pending.begin(generic: generic, handler: contentHandler)
    guard let recordID = CompanionRequestAlerts.recordID(fromPush: request.content.userInfo) else {
      Self.logger.notice("push: not a request's, delivered as it came")
      pending.deliver(nil, diagnostic: "pas une demande")
      return
    }
    Self.logger.notice("push: request \(recordID.recordName, privacy: .public), fetching")
    let pending = pending
    Task {
      do {
        guard let companionRequest = try await CompanionRequestAlerts.fetchRequest(recordID),
          let alert = CompanionRequestAlerts.alert(for: companionRequest)
        else {
          Self.logger.error("fetch: no request to read, generic alert")
          pending.deliver(nil, diagnostic: "demande illisible")
          return
        }
        Self.logger.notice("fetch: request read, alert written")
        pending.deliver(PendingAlert.Texts(title: alert.title, body: alert.body))
      } catch {
        Self.logger.error(
          "fetch: \(CompanionErrorText.describe(error), privacy: .public), generic alert")
        pending.deliver(nil, diagnostic: CompanionErrorText.describe(error))
      }
    }
  }

  /// iOS's time is up: the generic alert, unless the fetch delivered just before.
  override func serviceExtensionTimeWillExpire() {
    Self.logger.error("fetch: out of time, generic alert")
    pending.deliver(nil, diagnostic: "délai dépassé")
  }
}

/// The content handler and the generic alert, behind a lock: `didReceive`, the fetch's task and
/// `serviceExtensionTimeWillExpire` reach it from different threads, and the handler is called once.
private final class PendingAlert: @unchecked Sendable {
  struct Texts: Sendable {
    let title: String
    let body: String
  }

  private let lock = NSLock()
  private var handler: ((UNNotificationContent) -> Void)?
  private var content: UNMutableNotificationContent?

  func begin(
    generic: UNMutableNotificationContent, handler: @escaping (UNNotificationContent) -> Void
  ) {
    lock.withLock {
      content = generic
      self.handler = handler
    }
  }

  /// The request's texts on the generic alert — or `nil`, the generic alert as it is. Only the
  /// first call counts.
  /// `diagnostic`, the debug build only: why the alert stayed generic, as its subtitle — the
  /// extension's logs are out of reach without a cable (#368 trial).
  func deliver(_ texts: Texts?, diagnostic: String? = nil) {
    let delivery: (handler: (UNNotificationContent) -> Void, content: UNNotificationContent)? =
      lock.withLock {
        guard let handler, let content else { return nil }
        self.handler = nil
        self.content = nil
        if let texts {
          // A request without a session's title keeps « Vibe Manager ».
          if !texts.title.isEmpty { content.title = texts.title }
          content.body = texts.body
        }
        #if DEBUG
          if let diagnostic { content.subtitle = "Extension : \(diagnostic)" }
        #endif
        return (handler, content)
      }
    if let delivery { delivery.handler(delivery.content) }
  }

  /// The alert as CloudKit pushed it, copied for the texts to be replaced. Its keys are named by the
  /// subscription and localised by iOS; should they come unlocalised, this extension's own copy of
  /// the application's strings says them.
  static func generic(_ content: UNNotificationContent) -> UNMutableNotificationContent {
    let generic =
      content.mutableCopy() as? UNMutableNotificationContent ?? UNMutableNotificationContent()
    let title = CompanionRequestAlerts.LocalizationKey.title
    let body = CompanionRequestAlerts.LocalizationKey.body
    if generic.title.isEmpty || generic.title == title {
      generic.title = Bundle.main.localizedString(forKey: title, value: nil, table: nil)
    }
    if generic.body.isEmpty || generic.body == body {
      generic.body = Bundle.main.localizedString(forKey: body, value: nil, table: nil)
    }
    return generic
  }
}
