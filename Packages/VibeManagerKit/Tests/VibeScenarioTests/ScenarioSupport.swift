import Darwin
import Foundation
import Testing
import VibeAgents
import VibeApplication
import VibeComposition
import VibeDomain
import VibePersistence
import VibeTerminal
import VibeTerminalUI

@testable import VibeUI

/// The processes whose working directory is under a folder: what a scenario's agents, and whatever
/// they started, leave running. `proc_listallpids` and `proc_pidinfo`, read from the kernel.
enum ProcessTree {
  struct Entry: CustomStringConvertible {
    let processIdentifier: pid_t
    let workingDirectory: String
    var description: String { "\(processIdentifier) in \(workingDirectory)" }
  }

  static func snapshot(under root: String) -> [Entry] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var identifiers = [pid_t](repeating: 0, count: Int(count) * 2)
    let written = identifiers.withUnsafeMutableBytes { buffer in
      proc_listallpids(buffer.baseAddress, Int32(buffer.count))
    }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return identifiers.prefix(Int(max(0, written))).compactMap { pid in
      guard pid > 0, pid != getpid() else { return nil }
      var info = proc_bsdinfo()
      let size = proc_pidinfo(
        pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
      // A zombie has let go of everything; its parent will reap it.
      guard size > 0, info.pbi_status != UInt32(SZOMB) else { return nil }
      var paths = proc_vnodepathinfo()
      let pathSize = proc_pidinfo(
        pid, PROC_PIDVNODEPATHINFO, 0, &paths, Int32(MemoryLayout<proc_vnodepathinfo>.size))
      guard pathSize > 0 else { return nil }
      let directory = withUnsafeBytes(of: paths.pvi_cdir.vip_path) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
      }
      guard directory == root || directory.hasPrefix(prefix) else { return nil }
      return Entry(processIdentifier: pid, workingDirectory: directory)
    }
  }
}

/// Waits on a condition, never on the clock alone: the deadline only bounds a failure.
@MainActor
func eventually(
  timeout: Duration = .seconds(20),
  _ condition: @MainActor () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(25))
  }
  return await condition()
}

/// One composed application on a temporary folder: its data, its working folders, its host.
@MainActor
final class Scenario {
  let root: String
  let data: URL
  let suite: String
  private(set) var environments: [AppEnvironment] = []

  init(_ name: String = #function) throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeScenario-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // The kernel reports working directories through `/private`: `/var` is a link to it.
    root = url.path.withCString { path in
      guard let resolved = realpath(path, nil) else { return url.path }
      defer { free(resolved) }
      return String(cString: resolved)
    }
    data = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("Data")
    suite = "com.hadrienl.VibeManager.scenario.\(UUID().uuidString)"
  }

  var logs: DiagnosticsLocation {
    DiagnosticsLocation(directory: data.appendingPathComponent("Logs", isDirectory: true))
  }

  /// A working folder under the scenario's root.
  func folder(_ name: String) throws -> String {
    let path = (root as NSString).appendingPathComponent(name)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  /// The application, composed on this scenario's data folder, with two mock agents: `mock`,
  /// given `behaviour`, and `mock-b`, given `secondary`.
  func compose(
    behaviour: [String] = ["--hold"],
    secondary: [String] = ["--hold"],
    extraEnvironment: [String: String] = [:]
  ) throws -> AppEnvironment {
    let environment = [
      "VIBE_DATA_DIRECTORY": data.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "HOME": NSHomeDirectory(), "TERM": "xterm-256color",
    ].merging(extraEnvironment) { $1 }
    let launcher = ExecutableTerminalHostLauncher(
      executableURL: try Self.fixtureURL(),
      logDirectory: logs.directory,
      disclaimsResponsibility:
        ProcessInfo.processInfo.environment["VIBE_TESTS_WITHOUT_DISCLAIM"] == nil)
    let composed = AppEnvironment(
      configuration: AppEnvironment.Configuration(
        environment: environment,
        hostLaunch: .launcher(launcher),
        verifier: SameUserPeerVerifier(),
        providers: { _ in
          [
            MockAgentProvider(environment: environment, behaviour: behaviour),
            MockAgentProvider(environment: environment, secondary: true, behaviour: secondary),
          ]
        },
        defaultsSuite: suite,
        fullDiskAccessProbe: GrantedFullDiskAccess(),
        crashReports: URL(fileURLWithPath: root).appendingPathComponent("NoCrashReports")
      ))
    environments.append(composed)
    return composed
  }

  /// Creates a session through the New Session sheet, the way the user does, and launches it.
  @discardableResult
  func create(
    in environment: AppEnvironment,
    name: String,
    prompt: String = "",
    provider: String = "mock",
    folder: String
  ) async throws -> SessionID {
    let model = environment.appModel
    model.beginNewSession()
    let sheet = try #require(model.newSessionModel)
    await sheet.load(defaultWorkingDirectoryPath: nil)
    await sheet.refreshAgents(forceRefresh: false)
    await sheet.select(agent: provider)
    sheet.draft.name = name
    sheet.draft.initialPrompt = prompt
    await sheet.folderChosen(folder)
    let creation = await sheet.submit()
    let made = try #require(creation, "The sheet refused: \(sheet.issues)")
    await model.complete(made)
    return made.session.id
  }

  func pane(_ id: SessionID, in environment: AppEnvironment) -> TerminalPaneModel? {
    environment.appModel.pane(for: id)
  }

  /// Everything the session's terminal has shown.
  func output(_ id: SessionID, in environment: AppEnvironment) async -> String {
    guard let session = pane(id, in: environment)?.session else { return "" }
    return String(decoding: await session.history().bytes, as: UTF8.self)
  }

  func processIdentifier(_ id: SessionID, in environment: AppEnvironment) async -> pid_t? {
    guard let session = pane(id, in: environment)?.session,
      case .running(let pid) = await session.state()
    else { return nil }
    return pid
  }

  func type(_ text: String, into id: SessionID, in environment: AppEnvironment) async {
    await pane(id, in: environment)?.write(Array(text.utf8))
  }

  func stored(_ id: SessionID, in environment: AppEnvironment) -> WorkSession? {
    environment.appModel.sessions.first { $0.id == id }
  }

  /// Quits every composed application that is still up, stops whatever is left under the root,
  /// and removes the folder and the defaults suite.
  func tearDown() async {
    for environment in environments {
      await environment.shutdown(keepingAgentsRunning: false)
    }
    for entry in ProcessTree.snapshot(under: root) {
      kill(entry.processIdentifier, SIGKILL)
    }
    UserDefaults.standard.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(atPath: root)
  }

  /// The fixture sits next to the test bundle, found from the image this code was loaded from.
  static func fixtureURL() throws -> URL {
    var info = Dl_info()
    let found = withUnsafeMutablePointer(to: &scenarioAnchor) { dladdr($0, &info) }
    try #require(found != 0 && info.dli_fname != nil)
    var url = URL(fileURLWithPath: String(cString: info.dli_fname))
    while url.pathComponents.count > 1, url.pathExtension != "xctest" {
      url.deleteLastPathComponent()
    }
    let fixture = url.deletingLastPathComponent().appendingPathComponent("VibeTerminalHostFixture")
    try #require(FileManager.default.isExecutableFile(atPath: fixture.path))
    return fixture
  }
}

nonisolated(unsafe) private var scenarioAnchor: UInt8 = 0

struct GrantedFullDiskAccess: FullDiskAccessProbe {
  func status() async -> FullDiskAccessStatus { .granted }
}
