import AppKit
import SwiftUI
import Testing
import VibeApplication
import VibeDomain
import VibeTerminalUI

@testable import VibeUI

/// The status bar of a session at every width (#575): its buttons give up words together, step
/// by step, and none is ever drawn over another or cut.
@MainActor
@Suite("The status bar of a session, from wide to narrow", .serialized, .timeLimit(.minutes(2)))
struct StatusBarLayoutTests {
  /// A long model's name, and the longest effort's level.
  private static let provider = EffortProvider(
    base: WorkspaceProvider(
      id: "claude-code", name: "Claude Code",
      catalog: [AgentModel(id: StatusBarUsage.model, displayName: "Sonnet 4.5")]))

  /// An agent whose effort is "Extra High", the longest of the levels.
  private struct EffortProvider: AgentProvider, AgentEffortControlling {
    let base: WorkspaceProvider
    var descriptor: AgentDescriptor { base.descriptor }
    func availability(forceRefresh: Bool) async -> AgentAvailability {
      await base.availability(forceRefresh: forceRefresh)
    }
    func models() async -> [AgentModel] { await base.models() }
    func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
      try await base.launchPlan(for: request)
    }
    func effortLevels(modelID: String?) async -> [String] { ["low", "medium", "high", "xhigh"] }
    var offersDefaultEffort: Bool { true }
    func effortReport(resumeIdentifier: String?, since: Date) async -> AgentEffortReport {
      AgentEffortReport(configuredEffort: "xhigh")
    }
    func effortChange(to level: String?) -> AgentEffortChange? { nil }
  }

  private struct OneRegistry: AgentProviderResolving {
    let provider: EffortProvider
    func descriptors() async -> [AgentDescriptor] { [provider.descriptor] }
    func provider(id: AgentProviderID) async -> (any AgentProvider)? {
      id == provider.descriptor.id ? provider : nil
    }
    func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] {
      [provider.descriptor.id: await provider.availability(forceRefresh: forceRefresh)]
    }
  }

  private func waitUntil(_ condition: () -> Bool) async {
    while !condition() { await Task.yield() }
  }

  private struct Fixture {
    let model: AppModel
    let session: WorkSession
    let pane: TerminalPaneModel
  }

  private func fixture() async throws -> Fixture {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-status-bar-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let session = WorkSession(
      name: "Fix the VAT rounding",
      initialPrompt: "Fix it.",
      // A conversation of its own: its context is read, and the Usage button shows its share.
      agent: SessionAgentConfiguration(
        providerID: "claude-code", modelID: StatusBarUsage.model, resumeIdentifier: "conversation"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      closedAt: Date(timeIntervalSince1970: 1),
      repositories: [RepositoryContext(path: folder.path)]
    )
    let repository = WorkspaceRepository(sessions: [session])
    let registry = OneRegistry(provider: Self.provider)
    let supervisor = WorkspaceSupervisor()
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry, viewportTimeout: .zero)
    let path = folder.path
    let terminals = SessionTerminals(
      supervisor: supervisor, viewportTimeout: .milliseconds(1), sessionFolder: { _ in path })
    let usage = StatusBarUsage.usage(of: session.id)
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher, usage: usage,
      terminals: terminals)
    let plan = try await Self.provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: path))
    await launcher.launch(session: session, plan: plan)
    await model.reload()
    model.select(session.id)
    await waitUntil { model.pane(for: session.id)?.status == .running }
    await model.refreshEffort(of: session.id)
    await model.refreshAgents()
    // The figures, read as the button reads them once the session is shown.
    usage.startWatching(session.id)
    await usage.refresh()
    usage.stopWatching(session.id)
    let summary = SessionUsageSummary(
      figures: usage.sessionUsage[session.id], percent: usage.contextWindows[session.id]?.percentUsed)
    #expect(summary.cost != nil && summary.percent == 91, "the Usage button at its widest")
    let pane = try #require(model.pane(for: session.id))
    return Fixture(model: model, session: session, pane: pane)
  }

  /// Holds what the bar reported of its items.
  @MainActor
  final class Probe {
    var items: [StatusBarItemFrame] = []
  }

  /// Draws the bar `width` points wide, in a window never shown, and reads its controls as
  /// VoiceOver finds them. Writes it as a PNG in the folder `VIBE_STATUS_BAR_SNAPSHOTS` names,
  /// when it names one, to be looked at.
  private func draw(_ fixture: Fixture, width: CGFloat, language: String) async throws
    -> (items: [StatusBarItemFrame], bounds: CGRect)
  {
    _ = NSApplication.shared
    let probe = Probe()
    let host = NSHostingView(
      rootView: TerminalStatusBar(
        pane: fixture.pane,
        accessory: SessionStatusAccessory(model: fixture.model, session: fixture.session),
        close: {}
      )
      .environment(\.locale, Locale(identifier: language))
      .environment(\.reportsStatusBarItems, true)
      .onPreferenceChange(StatusBarItemFrames.self) { items in
        MainActor.assumeIsolated { probe.items = items }
      }
      .frame(width: width)
      .background(Color(nsColor: .windowBackgroundColor)))
    host.frame = NSRect(x: 0, y: 0, width: width, height: 34)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    // The step is chosen once the bar has said its width: a few passes of layout.
    for _ in 0..<20 {
      host.layoutSubtreeIfNeeded()
      await Task.yield()
    }
    if let folder = ProcessInfo.processInfo.environment["VIBE_STATUS_BAR_SNAPSHOTS"] {
      let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: image)
      let data = try #require(image.representation(using: .png, properties: [:]))
      try data.write(
        to: URL(fileURLWithPath: folder).appendingPathComponent(
          "status-bar-\(language)-\(Int(width)).png"))
    }
    return (probe.items, CGRect(x: 0, y: 0, width: width, height: host.bounds.height))
  }

  @Test("The step follows the width, from the widest to the narrowest")
  func stepsFollowTheWidth() {
    let steps = stride(from: 420, through: 1_000, by: 20).map {
      StatusBarDensity.fitting(CGFloat($0))
    }
    #expect(steps.first == .icons || steps.first == .gauge)
    #expect(steps.last == .full)
    // Never wider for a narrower bar.
    #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 >= $1 })
  }

  @Test(
    "No control is drawn over another, out of the bar or cut, from 420 to 1,000 points",
    arguments: ["en", "fr", "de"])
  func nothingOverlaps(language: String) async throws {
    let fixture = try await fixture()
    for width in stride(from: 420, through: 1_000, by: 20).map({ CGFloat($0) }) {
      let (controls, bounds) = try await draw(fixture, width: width, language: language)
      #expect(
        controls.map(\.name) == ["agent", "effort", "usage", "drawer", "close"], "\(Int(width))")
      for control in controls {
        #expect(bounds.contains(control.frame), "\(Int(width)): \(control.name) out of the bar")
      }
      for (index, control) in controls.enumerated() {
        for other in controls[(index + 1)...] {
          #expect(
            !control.frame.insetBy(dx: 0.5, dy: 0.5).intersects(other.frame),
            "\(Int(width)): \(control.name) over \(other.name)")
        }
      }
    }
  }

  @Test("The Usage button gives up its cost, then its share, at the bar's steps")
  func usageFollowsTheSteps() async throws {
    let fixture = try await fixture()
    var widths: [StatusBarDensity: Set<CGFloat>] = [:]
    for width in stride(from: 420, through: 1_000, by: 20).map({ CGFloat($0) }) {
      let (controls, _) = try await draw(fixture, width: width, language: "en")
      let usage = try #require(controls.first { $0.name == "usage" }, "\(Int(width))")
      widths[StatusBarDensity.fitting(width), default: []].insert(usage.frame.width.rounded())
    }
    // One form for each step: the whole value, then without the cost, then the ring alone.
    let full = try #require(widths[.full]), model = try #require(widths[.model])
    let level = try #require(widths[.level])
    let narrow = (widths[.gauge] ?? []).union(widths[.icons] ?? [])
    #expect(full.count == 1 && full == model)
    #expect(level.count == 1 && narrow.count == 1)
    #expect(full.first! > level.first! && level.first! > narrow.first!)
  }

  @Test("The step chooses the Usage button's widest form; the figures, the ones it has")
  func usageForms() {
    let label = SessionUsageLabel(
      summary: SessionUsageSummary(figures: SessionUsageLayoutTests.figures(), percent: 67),
      isReading: false)
    #expect(label.forms(at: .full) == [.full, .withoutCost, .ringAlone])
    #expect(label.forms(at: .model) == [.full, .withoutCost, .ringAlone])
    #expect(label.forms(at: .level) == [.withoutCost, .ringAlone])
    #expect(label.forms(at: .gauge) == [.ringAlone])
    #expect(label.forms(at: .icons) == [.ringAlone])
    // Without a known window, the running time stays: there is no ring to fall back on.
    let unknownWindow = SessionUsageLabel(
      summary: SessionUsageSummary(figures: SessionUsageLayoutTests.figures(), percent: nil),
      isReading: false)
    #expect(unknownWindow.forms(at: .full) == [.full, .withoutCost])
    #expect(unknownWindow.forms(at: .gauge) == [.withoutCost])
  }
}
