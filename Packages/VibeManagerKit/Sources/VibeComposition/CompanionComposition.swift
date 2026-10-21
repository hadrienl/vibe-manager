import Foundation
import Observation
import VibeApplication
import VibeCompanionLink
import VibeDomain
import VibeTerminal
import VibeUI
import os

/// The mobile companion of #347, wired: the sessions the workspace shows, published to the
/// companion agent whenever they change, and the tests it hands back, acknowledged and shown.
///
/// Only when the agent is in the bundle: builds of `Scripts/release.sh` do not carry it, nor does a
/// test that composes the application, so neither listens nor starts anything.
@MainActor
final class CompanionComposition {
  private static let logger = Logger(
    subsystem: "eu.hadrien.VibeManager.companion", category: "composition")
  private let link: CompanionLink
  private let publish: PublishCompanionSnapshot
  private weak var appModel: AppModel?
  /// The settings' model, which turns the companion on and off.
  private weak var model: MobileCompanionModel?
  /// The direct channel's end (#399).
  private var remote: CompanionRemoteServer?

  private init(link: CompanionLink, appModel: AppModel) {
    self.link = link
    self.appModel = appModel
    publish = PublishCompanionSnapshot(publisher: link)
  }

  /// `Contents/Helpers/Vibe Manager Companion.app`, when this build embeds it (`VIBE_EMBED_COMPANION`).
  nonisolated static func bundledAgent() -> URL? {
    guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
    let agent = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Helpers/Vibe Manager Companion.app", isDirectory: true)
    return FileManager.default.fileExists(atPath: agent.path) ? agent : nil
  }

  /// The companion's settings, and its agent when the user turned it on (#397). Off by default:
  /// nothing listens nor touches iCloud until then.
  static func start(
    agent: URL?, appModel: AppModel, dataFolder: URL, defaults: UserDefaults,
    diagnostics: Diagnostics
  ) -> CompanionComposition? {
    let availability: MobileCompanionModel.Availability =
      agent == nil ? .notEmbedded : isAppleSilicon ? .available : .needsAppleSilicon
    let model = MobileCompanionModel(availability: availability, defaults: defaults)
    appModel.companion = model
    guard let agent, availability == .available else { return nil }
    let hostLocation = TerminalHostLocation(dataDirectory: dataFolder)
    let link = CompanionLink(
      configuration: CompanionLink.Configuration(
        socketPath: hostLocation.directory.appendingPathComponent(CompanionLink.socketName).path,
        prepare: { try hostLocation.prepare() },
        agentBundle: agent,
        stateDirectory: dataFolder.appendingPathComponent("Companion", isDirectory: true),
        installationID: installationID(in: dataFolder),
        version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        buildLabel: buildLabel(applicationName: AppEnvironment.bundleName())),
      diagnostics: diagnostics)
    let composition = CompanionComposition(link: link, appModel: appModel)
    let remote = CompanionRemoteServer(
      appModel: appModel, macName: Host.current().localizedName ?? "Mac",
      attachmentsFolder: dataFolder.appendingPathComponent(
        "Companion/Attachments", isDirectory: true),
      send: { peer, message in Task { await link.sendRemote(message, to: peer) } })
    composition.remote = remote
    composition.model = model
    model.enabledChanged = { [weak composition] enabled in
      if enabled { composition?.launch() } else { composition?.halt() }
    }
    model.removePhoneAction = { endpointID in Task { await link.removeDevice(endpointID) } }
    if model.isEnabled { composition.launch() }
    composition.observe()
    return composition
  }

  /// The agent's network library ships for Apple silicon only.
  private static var isAppleSilicon: Bool {
    #if arch(arm64)
      return true
    #else
      // An Intel build of the application under Rosetta still runs on Apple silicon.
      var translated: Int32 = 0
      var size = MemoryLayout<Int32>.size
      return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0
        && translated == 1
    #endif
  }

  private func launch() {
    model?.update(state: .starting)
    let link = self.link
    let receive = ReceiveCompanionTest(publisher: link, alerts: AppKitCompanionTestAlert())
    let remote = self.remote
    Task {
      await link.start(
        onTest: { test in await receive(test) },
        onRemote: { peer, message in
          await MainActor.run {
            if let message { remote?.receive(message, from: peer) } else { remote?.closed(peer) }
          }
        },
        onEvent: { [weak self] event in
          await MainActor.run { self?.apply(event) }
        })
    }
  }

  /// The application quits: the agent sees its socket close, writes the Mac offline, and goes.
  func stop() async {
    await link.stop()
  }

  /// The user turned it off: the agent writes the Mac offline and quits, the phones are let go.
  private func halt() {
    connected = [:]
    Task { await link.stop() }
  }

  /// The phones connected now, by connection, with their endpoint.
  private var connected: [String: String] = [:] {
    didSet { model?.update(connected: Set(connected.values)) }
  }

  private func apply(_ event: CompanionLinkEvent) {
    guard let model, model.isEnabled else { return }
    switch event {
    case .status(let signedIn, let reachable):
      model.update(state: signedIn ? (reachable ? .running : .starting) : .noAccount)
    case .devices(let devices):
      model.update(
        phones: devices.map {
          MobileCompanionModel.Phone(id: $0.endpointID, name: $0.name, addedAt: $0.addedAt)
        })
    case .phoneConnected(let peer, let endpointID):
      connected[peer] = endpointID
    case .phoneLeft(let peer):
      connected[peer] = nil
    case .agentGone:
      model.update(state: .failed)
    }
  }

  /// Reads the sessions and their activity under observation, hands the snapshot over, and reads
  /// them again at the next change: one snapshot per change, which the use case coalesces.
  private func observe() {
    guard let appModel else { return }
    let snapshot = withObservationTracking {
      let names = Dictionary(
        appModel.agentDescriptors.map { ($0.id.rawValue, $0.displayName) },
        uniquingKeysWith: { first, _ in first })
      // `activity(for:)` per session rather than every activity at once: each session's cell is
      // then observed, including the first state of a session that just started.
      return CompanionSnapshot.make(
        sessions: appModel.sessions, activity: { appModel.activity(for: $0) },
        agentName: { names[$0] ?? $0 })
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe() }
    }
    Self.logger.notice(
      "sessions read: \(snapshot.sessions.count, privacy: .public) active, handed to the publication"
    )
    publish.update(snapshot)
  }

  /// This copy of the application, kept beside its data: an isolated copy is another Mac to the
  /// phone, on the same iCloud account.
  private static func installationID(in dataFolder: URL) -> String {
    let file = dataFolder.appendingPathComponent("companion-installation", isDirectory: false)
    if let data = FileManager.default.contents(atPath: file.path),
      let id = UUID(
        uuidString: String(decoding: data, as: UTF8.self).trimmingCharacters(
          in: .whitespacesAndNewlines))
    {
      return id.uuidString
    }
    let id = UUID().uuidString
    FileManager.default.createFile(
      atPath: file.path, contents: Data(id.utf8), attributes: [.posixPermissions: 0o600])
    return id
  }

  /// "Vibe Manager #347 abc1234" — the name `Scripts/local-build.sh` gives a test build — says
  /// "#347 abc1234"; a plain build says nothing more than its version.
  static func buildLabel(applicationName: String?) -> String {
    guard let name = applicationName, name.hasPrefix("Vibe Manager") else { return "" }
    return name.dropFirst("Vibe Manager".count).trimmingCharacters(in: .whitespaces)
  }
}
