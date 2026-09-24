import Foundation
import VibeDomain

/// Everything a diagnostics export holds, gathered once and already reduced to what may leave the
/// Mac: no session name, prompt, note, folder or terminal content can be represented here.
public struct DiagnosticSnapshot: Sendable {
  public struct Application: Sendable {
    public var version: DiagnosticVersion?
    public var build: DiagnosticVersion?
    public var operatingSystem: DiagnosticVersion?
    public var architecture: DiagnosticToken
    public var signature: DiagnosticToken
    /// A Team ID is ten letters and digits, public in every signed binary.
    public var teamIdentifier: DiagnosticVersion?
    public var hardenedRuntime: Bool

    public init(
      version: DiagnosticVersion?, build: DiagnosticVersion?, operatingSystem: DiagnosticVersion?,
      architecture: DiagnosticToken, signature: DiagnosticToken,
      teamIdentifier: DiagnosticVersion?, hardenedRuntime: Bool
    ) {
      self.version = version
      self.build = build
      self.operatingSystem = operatingSystem
      self.architecture = architecture
      self.signature = signature
      self.teamIdentifier = teamIdentifier
      self.hardenedRuntime = hardenedRuntime
    }
  }

  public struct Settings: Sendable {
    public var quitBehavior: DiagnosticToken
    public var confirmsStoppingRunningAgent: Bool
    public var fileEditor: DiagnosticToken
    public var verboseDiagnostics: Bool
    public var isolatedData: Bool
    public var terminalHost: Bool

    public init(
      quitBehavior: DiagnosticToken, confirmsStoppingRunningAgent: Bool,
      fileEditor: DiagnosticToken,
      verboseDiagnostics: Bool, isolatedData: Bool, terminalHost: Bool
    ) {
      self.quitBehavior = quitBehavior
      self.confirmsStoppingRunningAgent = confirmsStoppingRunningAgent
      self.fileEditor = fileEditor
      self.verboseDiagnostics = verboseDiagnostics
      self.isolatedData = isolatedData
      self.terminalHost = terminalHost
    }
  }

  public struct Agent: Sendable {
    public var provider: DiagnosticToken
    public var state: DiagnosticToken
    public var version: DiagnosticVersion?
    public var directory: RedactedPath?
    public var source: DiagnosticToken?
    /// `authenticated`, `unauthenticated` or `unknown`, as the last detection left it: the export
    /// never asks the agent again.
    public var authentication: DiagnosticToken
    public var remediations: [DiagnosticToken]
    public var probedAt: Date

    public init(
      provider: DiagnosticToken, state: DiagnosticToken, version: DiagnosticVersion?,
      directory: RedactedPath?, source: DiagnosticToken?, authentication: DiagnosticToken,
      remediations: [DiagnosticToken], probedAt: Date
    ) {
      self.provider = provider
      self.state = state
      self.version = version
      self.directory = directory
      self.source = source
      self.authentication = authentication
      self.remediations = remediations
      self.probedAt = probedAt
    }

    /// The last detection of an agent, as the workspace holds it.
    public init(_ diagnostic: AgentDiagnostic) {
      provider = diagnostic.providerID.diagnosticToken
      state = diagnostic.state.diagnosticToken
      version = diagnostic.installation?.version.flatMap { DiagnosticVersion("\($0)") }
      directory = diagnostic.installation.map {
        RedactedPath(URL(fileURLWithPath: $0.executablePath).deletingLastPathComponent().path)
      }
      source = diagnostic.installation.map { $0.source.diagnosticToken }
      switch diagnostic.state {
      case .available: authentication = "authenticated"
      case .unauthenticated: authentication = "unauthenticated"
      case .outdated, .notFound, .notExecutable, .probeFailed: authentication = "unknown"
      }
      remediations = diagnostic.remediations.map(\.diagnosticToken)
      probedAt = diagnostic.probedAt
    }
  }

  public struct Store: Sendable {
    public var schemaVersion: Int?
    public var sessionsByStatus: [SessionStatus: Int]
    public var storeBytes: Int?
    public var backupBytes: Int?
    public var backupModifiedAt: Date?
    public var corruptCopies: Int
    public var noteFiles: Int
    public var noteBytes: Int

    public init(
      schemaVersion: Int?, sessionsByStatus: [SessionStatus: Int], storeBytes: Int?,
      backupBytes: Int?, backupModifiedAt: Date?, corruptCopies: Int, noteFiles: Int,
      noteBytes: Int
    ) {
      self.schemaVersion = schemaVersion
      self.sessionsByStatus = sessionsByStatus
      self.storeBytes = storeBytes
      self.backupBytes = backupBytes
      self.backupModifiedAt = backupModifiedAt
      self.corruptCopies = corruptCopies
      self.noteFiles = noteFiles
      self.noteBytes = noteBytes
    }
  }

  public struct HostSession: Sendable {
    public var session: SessionPseudonym
    public var state: DiagnosticToken

    public init(session: SessionPseudonym, state: DiagnosticToken) {
      self.session = session
      self.state = state
    }
  }

  public struct Host: Sendable {
    public var processIdentifier: Int32
    public var startedAt: Date?
    public var protocolVersion: Int
    public var sessions: [HostSession]

    public init(
      processIdentifier: Int32, startedAt: Date?, protocolVersion: Int, sessions: [HostSession]
    ) {
      self.processIdentifier = processIdentifier
      self.startedAt = startedAt
      self.protocolVersion = protocolVersion
      self.sessions = sessions
    }
  }

  public struct Runtime: Sendable {
    public var phase: DiagnosticToken?
    public var updatedAt: Date?
    public var recordedSessions: Int
    public var previousShutdown: DiagnosticToken?
    public var host: Host?
    public var sessionsRunningInApplication: Int

    public init(
      phase: DiagnosticToken?, updatedAt: Date?, recordedSessions: Int,
      previousShutdown: DiagnosticToken?, host: Host?, sessionsRunningInApplication: Int
    ) {
      self.phase = phase
      self.updatedAt = updatedAt
      self.recordedSessions = recordedSessions
      self.previousShutdown = previousShutdown
      self.host = host
      self.sessionsRunningInApplication = sessionsRunningInApplication
    }
  }

  /// A file carried as it is: a log already made of safe values, or a crash report whose paths
  /// have been redacted.
  public struct Attachment: Sendable {
    public var name: String
    public var contents: Data

    public init(name: String, contents: Data) {
      self.name = name
      self.contents = contents
    }
  }

  public var createdAt: Date
  public var application: Application
  public var settings: Settings
  public var agents: [Agent]
  public var store: Store
  public var runtime: Runtime
  public var logs: [Attachment]
  public var crashReports: [Attachment]

  public init(
    createdAt: Date, application: Application, settings: Settings, agents: [Agent], store: Store,
    runtime: Runtime, logs: [Attachment], crashReports: [Attachment]
  ) {
    self.createdAt = createdAt
    self.application = application
    self.settings = settings
    self.agents = agents
    self.store = store
    self.runtime = runtime
    self.logs = logs
    self.crashReports = crashReports
  }
}

extension AgentRemediation {
  var diagnosticToken: DiagnosticToken {
    switch self {
    case .install: return "install"
    case .update: return "update"
    case .authenticate: return "authenticate"
    case .defineExecutablePath: return "defineExecutablePath"
    case .retryDetection: return "retryDetection"
    }
  }
}

/// One file of the export.
public struct DiagnosticFile: Hashable, Sendable {
  public let name: String
  public let contents: Data

  public init(name: String, contents: Data) {
    self.name = name
    self.contents = contents
  }

  public var text: String { String(decoding: contents, as: UTF8.self) }
}

/// Turns a snapshot into the files of the export. Pure: the canary scenario and the preview the
/// user reads before saving both go through it.
public enum DiagnosticArchive {
  /// Said on the sheet, before anything is saved.
  public static let exclusions =
    "Not included: what the terminals showed, prompts, notes, and the names of sessions and folders."

  public static func files(from snapshot: DiagnosticSnapshot) -> [DiagnosticFile] {
    var files = [
      DiagnosticFile(name: "summary.txt", contents: Data(summary(snapshot).utf8)),
      DiagnosticFile(name: "agents.txt", contents: Data(agents(snapshot).utf8)),
      DiagnosticFile(name: "store.txt", contents: Data(store(snapshot).utf8)),
      DiagnosticFile(name: "runtime.txt", contents: Data(runtime(snapshot).utf8)),
    ]
    files += snapshot.logs.map { DiagnosticFile(name: "logs/\($0.name)", contents: $0.contents) }
    files += snapshot.crashReports.map {
      DiagnosticFile(name: "crashes/\($0.name)", contents: $0.contents)
    }
    return files
  }

  /// The whole export as one text: exactly what will be written, file after file.
  public static func preview(of files: [DiagnosticFile]) -> String {
    files.map { file in
      "=== \(file.name) (\(file.contents.count) bytes) ===\n\(file.text)"
    }.joined(separator: "\n\n")
  }

  public static func suggestedFileName(at date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH.mm"
    return "Vibe Manager Diagnostics \(formatter.string(from: date)).zip"
  }

  private static func date(_ date: Date?) -> String {
    guard let date else { return "none" }
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: date)
  }

  private static func summary(_ snapshot: DiagnosticSnapshot) -> String {
    let application = snapshot.application
    let settings = snapshot.settings
    return """
      Vibe Manager diagnostics
      Created: \(date(snapshot.createdAt))
      \(exclusions)

      Version: \(application.version?.rawValue ?? "unknown") (\(application.build?.rawValue ?? "unknown"))
      macOS: \(application.operatingSystem?.rawValue ?? "unknown")
      Architecture: \(application.architecture.rawValue)
      Signature: \(application.signature.rawValue)
      Team: \(application.teamIdentifier?.rawValue ?? "none")
      Hardened runtime: \(application.hardenedRuntime ? "yes" : "no")

      Settings
      Quit with agents running: \(settings.quitBehavior.rawValue)
      Confirm stopping a running agent: \(settings.confirmsStoppingRunningAgent ? "yes" : "no")
      File editor: \(settings.fileEditor.rawValue)
      Verbose diagnostics: \(settings.verboseDiagnostics ? "yes" : "no")
      Isolated data directory: \(settings.isolatedData ? "yes" : "no")
      Terminal host: \(settings.terminalHost ? "on" : "off")

      """
  }

  private static func agents(_ snapshot: DiagnosticSnapshot) -> String {
    guard !snapshot.agents.isEmpty else { return "No agent has been detected yet.\n" }
    return snapshot.agents.map { agent in
      """
      Provider: \(agent.provider.rawValue)
      State: \(agent.state.rawValue)
      Version: \(agent.version?.rawValue ?? "unknown")
      Directory: \(agent.directory?.rawValue ?? "none")
      Found through: \(agent.source?.rawValue ?? "none")
      Authentication: \(agent.authentication.rawValue)
      Remedies: \(agent.remediations.map(\.rawValue).joined(separator: ", "))
      Detected: \(date(agent.probedAt))

      """
    }.joined(separator: "\n")
  }

  private static func store(_ snapshot: DiagnosticSnapshot) -> String {
    let store = snapshot.store
    let counts = SessionStatus.allCases.map { "\($0.rawValue): \(store.sessionsByStatus[$0] ?? 0)" }
    return """
      Schema version: \(store.schemaVersion.map(String.init) ?? "unknown")
      Sessions: \(counts.joined(separator: ", "))
      Store size: \(store.storeBytes.map { "\($0) bytes" } ?? "absent")
      Backup: \(store.backupBytes.map { "\($0) bytes, \(date(store.backupModifiedAt))" } ?? "absent")
      Damaged copies kept: \(store.corruptCopies)
      Note files: \(store.noteFiles), \(store.noteBytes) bytes

      """
  }

  private static func runtime(_ snapshot: DiagnosticSnapshot) -> String {
    let runtime = snapshot.runtime
    var lines = [
      "Runtime document: \(runtime.phase?.rawValue ?? "absent"), updated \(date(runtime.updatedAt))",
      "Sessions recorded in it: \(runtime.recordedSessions)",
      "Previous shutdown: \(runtime.previousShutdown?.rawValue ?? "not detected")",
      "Sessions running inside the application: \(runtime.sessionsRunningInApplication)",
    ]
    if let host = runtime.host {
      lines.append(
        "Terminal host: pid \(host.processIdentifier), started \(date(host.startedAt)), "
          + "protocol \(host.protocolVersion), \(host.sessions.count) sessions")
      for session in host.sessions {
        lines.append("  \(session.session.rawValue): \(session.state.rawValue)")
      }
    } else {
      lines.append("Terminal host: not connected")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
