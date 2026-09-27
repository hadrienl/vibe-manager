import AppKit
import SwiftUI
import Testing
import VibeDomain
import VibeLocalizationTesting

@testable import VibeApplication
@testable import VibeUI

/// The Usage section at the narrowest context column (#130).
@MainActor
@Suite("The usage of a session in a narrow context column", .timeLimit(.minutes(1)))
struct SessionUsageLayoutTests {
  /// The narrowest context column, less the section's horizontal padding.
  nonisolated static let narrowWidth = WorkspaceLayout.inspectorWidthRange.lowerBound - 24

  static func figures() -> SessionUsage {
    var total = UsageRow(key: .total)
    total.runningTime = 3 * 3600 + 12 * 60
    total.runs.starts = 1
    total.runs.resumes = 12
    total.runs.afterRelaunch = 2
    total.runs.afterSwitch = 1
    total.tokens = TokenCounts(input: 6, cacheRead: 111_000, cacheWrite: 21_500, output: 1_100)
    total.responses = 48
    total.hasReportedTokens = true
    var opus = UsageRow(key: .model(providerID: "claude", model: "claude-opus-5-5"))
    opus.tokens = TokenCounts(input: 4, cacheRead: 98_000, cacheWrite: 20_100, output: 1_000)
    opus.hasReportedTokens = true
    var standard = UsageRow(key: .model(providerID: "claude", model: nil))
    standard.tokens = TokenCounts(input: 2, cacheRead: 13_000, cacheWrite: 1_400, output: 100)
    standard.hasReportedTokens = true
    return SessionUsage(
      total: total, models: [opus, standard], hasTranscript: true, transcriptMissingSince: nil)
  }

  static func section(language: String) -> some View {
    SessionUsageFigures(
      figures: figures(), isTrackingEnabled: true, runsRecordedSince: nil,
      tokenUnavailability: nil, agentNames: ["claude": "Claude Code"]
    )
    .environment(\.locale, Locale(identifier: language))
  }

  /// The widest context column, less the section's horizontal padding.
  nonisolated static let wideWidth = WorkspaceLayout.inspectorWidthRange.upperBound - 24

  /// How wide a line of text is drawn, unwrapped.
  static func width(of text: String, font: Font = .callout) -> CGFloat {
    NSHostingView(rootView: Text(verbatim: text).font(font).monospacedDigit().fixedSize())
      .fittingSize.width
  }

  @Test(
    "Each label, and each part of a value, fits on a line of the narrowest column",
    arguments: ["en", "fr"])
  func partsFit(language: String) {
    _ = NSApplication.shared
    let locale = Locale(identifier: language)
    var runs = UsageRunCounts()
    runs.starts = 88
    runs.resumes = 888
    runs.restarts = 8
    runs.afterRelaunch = 8
    runs.afterSwitch = 88
    let tokens = TokenCounts(
      input: 888_888, cacheRead: 888_888_888, cacheWrite: 888_888_888, output: 888_888)
    let labels = ["Running time", "Runs", "Tokens", "Responses", "Cost"].map {
      Localization.string($0, module: "VibeUI", in: language)
    }
    let parts =
      UsagePresentation.runParts(runs, locale: locale)
      + UsagePresentation.tokenParts(tokens, locale: locale).map { "≈ " + $0 }
    #expect(labels.allSatisfy { !$0.isEmpty })
    for text in labels + parts {
      #expect(Self.width(of: text) <= Self.narrowWidth, "\(text)")
    }
  }

  /// Draws the section in a window never shown, and writes it as a PNG in the folder
  /// `VIBE_USAGE_SNAPSHOTS` names, when it names one, to be looked at.
  @Test(
    "The section is drawn no wider than the column",
    arguments: [("en", narrowWidth), ("fr", narrowWidth), ("en", wideWidth), ("fr", wideWidth)])
  func draw(language: String, width: Double) throws {
    _ = NSApplication.shared
    let host = NSHostingView(
      rootView: Self.section(language: language)
        .frame(width: width, alignment: .leading)
        .padding(12)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor)))
    let size = host.fittingSize
    #expect(size.width <= width + 24 + 0.5)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()

    guard let folder = ProcessInfo.processInfo.environment["VIBE_USAGE_SNAPSHOTS"] else { return }
    let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: image)
    let data = try #require(image.representation(using: .png, properties: [:]))
    try data.write(
      to: URL(fileURLWithPath: folder).appendingPathComponent("usage-\(language)-\(Int(width)).png")
    )
  }
}
