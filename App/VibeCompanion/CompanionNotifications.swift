import CompanionCore
import CompanionKit
import Foundation
import Observation
import UIKit
import UserNotifications
import os

/// The visible notifications of the Mac's requests (#368): the permission, the registration with
/// APNs, and the CloudKit subscription that turns each `Request` record into an alert. What the
/// debug screen's « Notifications » section shows.
///
/// The alert is built and pushed by CloudKit's servers: none of this code runs for a locked phone
/// or an application in the background. It only runs to set things up, and to note what arrives
/// while the application is open.
@Observable
@MainActor
final class CompanionNotifications {
  enum SubscriptionState: Equatable {
    case notSaved
    case saving
    case saved
    case failed(String)
  }

  /// A notification shown while the application was open, or tapped.
  struct Delivery: Equatable {
    let title: String
    let body: String
    let date: Date
  }

  private static let logger = Logger(
    subsystem: "eu.hadrien.VibeManager.companion", category: "notify")
  /// How often a subscription that failed is tried again: it fails until the Mac wrote a first
  /// request, which makes the record type in the Development schema.
  private static let retryInterval: TimeInterval = 30

  private(set) var permission: UNAuthorizationStatus = .notDetermined
  private(set) var subscription = SubscriptionState.notSaved
  /// "jeton reçu", or the registration's error.
  private(set) var registration: String?
  private(set) var lastDelivery: Delivery?
  private var lastAttempt: Date?
  private var isStarted = false

  /// Asks the user once — alert, sound, badge — registers with APNs, and saves the subscription.
  func start() async {
    guard !isStarted else { return }
    isStarted = true
    let center = UNUserNotificationCenter.current()
    do {
      let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
      Self.logger.notice("permission: \(granted ? "granted" : "refused", privacy: .public)")
    } catch {
      Self.logger.error("permission: \(error.localizedDescription, privacy: .public)")
    }
    await refreshPermission()
    // After the sync engine's start, which registers on its own: asked again here for the token's
    // answer to show, which the engine keeps to itself.
    UIApplication.shared.registerForRemoteNotifications()
    await saveSubscription()
  }

  /// Back in the foreground: the permission may have changed in Settings, and a subscription that
  /// failed is tried again.
  func refresh() async {
    await refreshPermission()
    try? await UNUserNotificationCenter.current().setBadgeCount(0)
    guard isStarted, subscription != .saved, subscription != .saving else { return }
    if let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.retryInterval { return }
    await saveSubscription()
  }

  func registered(tokenLength: Int) {
    Self.logger.notice("push: registered, token of \(tokenLength, privacy: .public) bytes")
    registration = "jeton reçu"
  }

  func registrationFailed(_ error: any Error) {
    Self.logger.error("push: registration failed: \(error.localizedDescription, privacy: .public)")
    registration = "échec : \(error.localizedDescription)"
  }

  func delivered(_ delivery: Delivery) {
    Self.logger.notice("notification: delivered")
    lastDelivery = delivery
  }

  private func refreshPermission() async {
    permission = await UNUserNotificationCenter.current().notificationSettings()
      .authorizationStatus
  }

  private func saveSubscription() async {
    subscription = .saving
    lastAttempt = Date()
    do {
      try await CompanionRequestAlerts.save()
      subscription = .saved
    } catch {
      let text = CompanionErrorText.describe(error)
      Self.logger.error("subscription: \(text, privacy: .public)")
      subscription = .failed(text)
    }
  }
}

extension UNAuthorizationStatus {
  /// Said on the debug screen, in French.
  var label: String {
    switch self {
    case .notDetermined: "pas encore demandée"
    case .denied: "refusée"
    case .authorized: "accordée"
    case .provisional: "provisoire"
    case .ephemeral: "éphémère"
    @unknown default: "inconnue"
    }
  }
}
