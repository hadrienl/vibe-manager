import AppKit
import Foundation
import VibeApplication
import os

/// The alert of a test from the phone (#347): who sent it, when, and how long it took.
///
/// Modal to the application, so that it is seen; if the application is behind another, its Dock
/// icon bounces once rather than stealing the focus. Tests that arrive while one is up are shown
/// afterwards, one by one. The acknowledgement has already left: this alert only tells the user.
@MainActor
public final class AppKitCompanionTestAlert: CompanionTestAlerting {
  private static let logger = Logger(
    subsystem: "eu.hadrien.VibeManager.companion", category: "alert")
  private var queue: [(test: CompanionTest, receivedAt: Date)] = []
  private var isShowing = false

  public init() {
    // Nothing to set up: an alert is made for each test.
  }

  public func present(_ test: CompanionTest, receivedAt: Date) {
    queue.append((test, receivedAt))
    guard !isShowing else { return }
    // Later, not within the caller, and from the run loop rather than a task: a modal alert runs a
    // loop of its own until dismissed, and run from the main queue it would hold every task of the
    // main actor behind it — the window, the terminals — for as long as it is up.
    RunLoop.main.perform(inModes: [.default]) {
      MainActor.assumeIsolated { [weak self] in self?.showQueued() }
    }
  }

  private func showQueued() {
    guard !isShowing else { return }
    isShowing = true
    defer { isShowing = false }
    while !queue.isEmpty {
      let (test, receivedAt) = queue.removeFirst()
      let alert = NSAlert()
      alert.messageText = String(localized: "Companion test received", bundle: .module)
      alert.informativeText = Self.details(of: test, receivedAt: receivedAt)
      alert.icon = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
      alert.addButton(withTitle: String(localized: "OK", bundle: .module))
      if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
      Self.logger.notice("alert shown for test \(test.nonce, privacy: .public)")
      alert.runModal()
    }
  }

  /// "“iPhone” sent a test at 10:42:03. Received at 10:42:05, 2.0 sec later." The delay crosses the
  /// clocks of both devices: an estimate, which their drift can even make negative.
  static func details(of test: CompanionTest, receivedAt: Date) -> String {
    let sent = test.sentAt.formatted(date: .omitted, time: .standard)
    let received = receivedAt.formatted(date: .omitted, time: .standard)
    let delay = Duration.milliseconds(Int64(receivedAt.timeIntervalSince(test.sentAt) * 1_000))
      .formatted(.units(allowed: [.seconds], width: .abbreviated, fractionalPart: .show(length: 1)))
    let device = test.deviceName
    return String(
      localized: "“\(device)” sent a test at \(sent).\nReceived at \(received), \(delay) later.",
      bundle: .module,
      comment:
        "The alert of a test from the phone. The phone's name, the time it sent the test, the time the Mac received it, and the delay between them."
    )
  }
}
