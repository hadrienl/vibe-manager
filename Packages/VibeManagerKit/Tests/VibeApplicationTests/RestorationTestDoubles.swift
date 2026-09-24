import Foundation
import VibeApplication
import VibeDomain

// The doubles the restoration suites share.
//
// One copy, in the manner of `AgentTestDoubles` and `TerminalTestSupport`: quitting, detecting a
// previous shutdown and restoring a queue all need the same store, the same clock and the same
// view of what a process is, and three copies of each would drift apart one fix at a time.

/// The order in which things happened, for the suites whose whole assertion is an order.
actor RestorationJournal {
  private(set) var entries: [String] = []

  func record(_ entry: String) {
    entries.append(entry)
  }

  func clear() {
    entries.removeAll()
  }
}

/// A store that keeps its sessions in memory, and optionally says when it was written to.
actor RestorationRepository: SessionRepository {
  private var stored: [WorkSession]
  private let journal: RestorationJournal?
  /// A store that cannot be listed, as a volume that has gone away is.
  private let listingFails: Bool

  init(sessions: [WorkSession], journal: RestorationJournal? = nil, listingFails: Bool = false) {
    stored = sessions
    self.journal = journal
    self.listingFails = listingFails
  }

  func status(of id: SessionID) -> SessionStatus? {
    stored.first { $0.id == id }?.status
  }

  func sessions() throws -> [WorkSession] {
    if listingFails { throw CocoaError(.fileReadNoPermission) }
    return stored
  }

  func session(id: SessionID) -> WorkSession? { stored.first { $0.id == id } }

  func save(_ session: WorkSession) {
    if let index = stored.firstIndex(where: { $0.id == session.id }) {
      stored[index] = session
    } else {
      stored.append(session)
    }
  }

  func mutate(
    id: SessionID,
    _ transform: @Sendable (inout WorkSession) throws -> Void
  ) async throws -> WorkSession? {
    guard let index = stored.firstIndex(where: { $0.id == id }) else { return nil }
    var session = stored[index]
    try transform(&session)
    stored[index] = session
    await journal?.record("close:\(id)")
    return session
  }
}

/// A system whose processes a test decides on, and which records what it was asked to kill.
///
/// A lock rather than an actor: the probe is synchronous by contract — a leftover check must not
/// be able to suspend in the middle of deciding whether to send a signal.
final class RestorationProcesses: ProcessLivenessProbe, @unchecked Sendable {
  private let lock = NSLock()
  private let alive: Set<Int32>
  private let startTimes: [Int32: Date]
  private var killed: [Int32] = []

  init(alive: Set<Int32> = [], startTimes: [Int32: Date] = [:]) {
    self.alive = alive
    self.startTimes = startTimes
  }

  var terminated: [Int32] {
    lock.withLock { killed }
  }

  func isAlive(processIdentifier: Int32) -> Bool {
    alive.contains(processIdentifier)
  }

  func startTime(of processIdentifier: Int32) -> Date? {
    startTimes[processIdentifier]
  }

  @discardableResult
  func terminate(processGroup: Int32) -> Bool {
    lock.withLock { killed.append(processGroup) }
    return true
  }
}

struct RestorationClock: SessionClock {
  let value: Date

  init(_ value: Date) {
    self.value = value
  }

  func now() -> Date { value }
}

struct RestorationFolders: WorkingDirectoryProbe {
  var status: WorkingDirectoryStatus = .usable

  func inspect(path: String) async -> WorkingDirectoryStatus { status }
}

struct RestorationProvider: AgentProvider {
  let descriptor: AgentDescriptor
  let state: AgentAvailabilityState
  let launchFailure: AgentLaunchError?
  /// Raised only when a resume is asked for, as a CLI refusing a stored identifier would.
  let resumeFailure: AgentLaunchError?
  let catalog: [AgentModel]

  init(
    id: String = "stub",
    displayName: String = "Stub Agent",
    models: [AgentModel] = [],
    state: AgentAvailabilityState = .available,
    capabilities: AgentCapabilities = AgentCapabilities(
      supportsModelSelection: true,
      supportsInitialPrompt: true,
      supportsResume: true
    ),
    launchFailure: AgentLaunchError? = nil,
    resumeFailure: AgentLaunchError? = nil
  ) {
    descriptor = AgentDescriptor(
      id: AgentProviderID(id),
      displayName: displayName,
      capabilities: capabilities
    )
    catalog = models
    self.state = state
    self.launchFailure = launchFailure
    self.resumeFailure = resumeFailure
  }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentAvailability(
      state: state,
      installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id,
        providerName: descriptor.displayName,
        state: state,
        summary: "\(descriptor.displayName) is \(state == .available ? "ready" : "unusable").",
        probedAt: Date(timeIntervalSince1970: 0),
        remediations: state == .available ? [] : [.install(documentationURL: nil)]
      )
    )
  }

  func models() async -> [AgentModel] { catalog }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    if let launchFailure { throw launchFailure }
    if let prompt = request.initialPrompt, prompt.utf8.count > AgentPromptLimits.argumentByteLimit {
      throw AgentLaunchError.promptTooLarge(
        byteCount: prompt.utf8.count, limit: AgentPromptLimits.argumentByteLimit)
    }
    if case .identifier = request.resume, let resumeFailure { throw resumeFailure }

    var arguments: [String] = []
    if case .identifier(let identifier) = request.resume {
      arguments.append(contentsOf: ["--resume", identifier])
    }
    if let modelID = request.modelID {
      arguments.append(contentsOf: ["--model", modelID])
    }
    if let prompt = request.initialPrompt {
      arguments.append(contentsOf: ["--", prompt])
    }
    return AgentLaunchPlan(
      providerID: descriptor.id,
      executablePath: "/usr/bin/true",
      arguments: arguments,
      environment: [:],
      workingDirectoryPath: request.workingDirectoryPath,
      promptDelivery: request.initialPrompt == nil ? .none : .argument
    )
  }
}

struct RestorationRegistry: AgentProviderResolving {
  var providers: [RestorationProvider]

  func descriptors() async -> [AgentDescriptor] { providers.map(\.descriptor) }

  func provider(id: AgentProviderID) async -> (any AgentProvider)? {
    providers.first { $0.descriptor.id == id }
  }

  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] {
    var result: [AgentProviderID: AgentAvailability] = [:]
    for provider in providers {
      result[provider.descriptor.id] = await provider.availability(forceRefresh: forceRefresh)
    }
    return result
  }
}
