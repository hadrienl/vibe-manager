import Foundation
import Observation
import VibeApplication
import VibeCompanionLink
import VibeDomain
import VibeTerminal
import VibeUI

/// The mobile companion of #347, wired: the sessions the workspace shows, published to the
/// companion agent whenever they change, and the tests it hands back, acknowledged and shown.
///
/// Only when the agent is in the bundle: builds of `Scripts/release.sh` do not carry it, nor does a
/// test that composes the application, so neither listens nor starts anything.
@MainActor
final class CompanionComposition {
  private let link: CompanionLink
  private let publish: PublishCompanionSnapshot
  private weak var appModel: AppModel?

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

  static func start(
    agent: URL?, appModel: AppModel, dataFolder: URL, diagnostics: Diagnostics
  ) -> CompanionComposition? {
    guard let agent else { return nil }
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
    let receive = ReceiveCompanionTest(publisher: link, alerts: AppKitCompanionTestAlert())
    Task {
      await link.start { test in await receive(test) }
    }
    composition.observe()
    return composition
  }

  func stop() async {
    await link.stop()
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
