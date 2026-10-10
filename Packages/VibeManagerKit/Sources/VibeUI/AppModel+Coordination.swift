import Foundation
import VibeApplication
import VibeBrowser
import VibeDomain

/// A coordinator's children, summed up on its row and in its section (#352).
public struct CoordinatorSummary: Equatable, Sendable {
  public let count: Int
  public let running: Int
  /// Children waiting for the user.
  public let needingUser: Int

  public static let none = CoordinatorSummary(count: 0, running: 0, needingUser: 0)
}

// MARK: - The hierarchy

extension AppModel {
  /// The coordinator a session is listed under, when it is listed under one (#352).
  public func coordinator(of session: WorkSession) -> WorkSession? {
    guard let id = session.coordination?.coordinatorID,
      let parent = sessions.first(where: { $0.id == id })
    else { return nil }
    return SessionHierarchy.parent(of: session, in: [id: parent])
  }

  /// A coordinator's children, archived ones aside, in the order of the store.
  public func children(of id: SessionID) -> [WorkSession] {
    CoordinationPolicy.children(of: id, among: sessions)
  }

  /// The column a session is listed in: its coordinator's, for a child listed under one.
  func listedColumn(of session: WorkSession) -> SessionTaskStatus {
    guard session.coordination?.coordinatorID != nil else { return session.taskStatus }
    return SessionHierarchy.column(of: session, in: SessionHierarchy.index(sessions))
  }

  public func isCoordinator(_ id: SessionID) -> Bool {
    sessions.first { $0.id == id }?.coordination?.isCoordinator == true
  }

  public func isExpanded(coordinator id: SessionID) -> Bool {
    !filter.trimmedSearchText.isEmpty || !layout.collapsedCoordinators.contains(id)
  }

  public func setExpanded(_ isExpanded: Bool, coordinator id: SessionID) {
    // As for groups: a fold made during a search would land unseen once it is cleared.
    guard canFold else { return }
    layout.setCollapsed(!isExpanded, coordinators: [id])
    pruneSelection()
  }

  /// The rows drawn: a folded coordinator's children are left out, unless a search is under way.
  func hidingFoldedChildren(_ listed: [WorkSession]) -> [WorkSession] {
    let collapsed = layout.collapsedCoordinators
    guard filter.trimmedSearchText.isEmpty, !collapsed.isEmpty else { return listed }
    var shownParents: Set<SessionID> = []
    return listed.filter { session in
      if let parent = session.coordination?.coordinatorID, shownParents.contains(parent) {
        return !collapsed.contains(parent)
      }
      if session.coordination?.isCoordinator == true { shownParents.insert(session.id) }
      return true
    }
  }

  public func summary(ofCoordinator id: SessionID) -> CoordinatorSummary {
    let children = children(of: id)
    return CoordinatorSummary(
      count: children.count,
      running: children.filter { launcher?.isRunning($0.id) == true }.count,
      needingUser: children.filter {
        if case .awaitingUser = activity(for: $0.id)?.activity { return true }
        return false
      }.count)
  }

  /// Whether a coordinator called the user and was not opened since.
  public func isCallingUser(_ id: SessionID) -> Bool {
    coordination.calls[id] != nil
  }

  /// What coordinators did to this child, oldest first.
  public func coordinationTrace(of id: SessionID) -> [CoordinationTraceEntry] {
    coordination.traces[id] ?? []
  }

  /// Reads the trace of a child shown in the inspector.
  public func loadCoordinationTrace(of id: SessionID) async {
    await coordination.loadTrace(of: id)
  }

  /// The session in front of the user changed: a coordinator that called them has been answered.
  func coordinationSessionShown(_ id: SessionID?) {
    guard let id, coordination.calls[id] != nil else { return }
    coordination.calls[id] = nil
  }

  /// How many children of a coordinator have their agent running.
  func runningChildren(of id: SessionID) -> Int {
    children(of: id).filter { launcher?.isRunning($0.id) == true }.count
      + coordination.startingChildren[id, default: 0]
  }
}

// MARK: - Closing a coordinator

extension AppModel {
  /// The children still running of a coordinator about to be stopped: the question offers to stop
  /// them too.
  public func runningChildren(ofCoordinator session: WorkSession) -> [WorkSession] {
    guard session.coordination?.isCoordinator == true else { return [] }
    return children(of: session.id).filter { launcher?.isRunning($0.id) == true }
  }

  /// Closes a coordinator's running children, as a batch close would, saying nothing (#352).
  public func closeChildren(of id: SessionID) async {
    for child in children(of: id) where launcher?.isRunning(child.id) == true {
      _ = await closeInBatch(child.id)
    }
    await reload()
  }
}

// MARK: - Events told to coordinators

extension AppModel {
  /// A child's agent changed state: a coordinator is told when it finished a turn, or waits for
  /// the user.
  func coordinationActivityChanged(
    _ id: SessionID, from previous: AgentActivityState?, to state: AgentActivityState,
    isReplayed: Bool
  ) {
    guard !isReplayed, let child = sessions.first(where: { $0.id == id }),
      let coordinatorID = child.coordination?.coordinatorID
    else { return }
    let kind: CoordinationEvent.Kind?
    switch (previous?.activity, state.activity) {
    case (.working?, .idle):
      kind = .turnEnded
    case (let before, .awaitingUser) where !Self.isAwaitingUser(before):
      kind = .awaitingUser(
        state.requests.first.map(CoordinationDigest.summary(of:)) ?? "an answer in its terminal")
    default:
      kind = nil
    }
    guard let kind else { return }
    tell(
      coordinatorID,
      CoordinationEvent(childID: id, childName: child.name, kind: kind, date: coordination.now()))
  }

  private static func isAwaitingUser(_ activity: AgentActivity?) -> Bool {
    if case .awaitingUser = activity { return true }
    return false
  }

  /// A child's agent stopped on its own.
  func coordinationProcessEnded(_ id: SessionID) {
    guard let child = sessions.first(where: { $0.id == id }),
      let coordinatorID = child.coordination?.coordinatorID
    else { return }
    tell(
      coordinatorID,
      CoordinationEvent(
        childID: id, childName: child.name, kind: .stopped, date: coordination.now()))
  }

  /// The user moved a child to another column.
  func coordinationStatusChangedByUser(_ id: SessionID, to status: SessionTaskStatus) {
    guard let child = sessions.first(where: { $0.id == id }),
      let coordinatorID = child.coordination?.coordinatorID
    else { return }
    tell(
      coordinatorID,
      CoordinationEvent(
        childID: id, childName: child.name, kind: .statusChanged(status), date: coordination.now()))
  }

  private func tell(_ coordinator: SessionID, _ event: CoordinationEvent) {
    // A coordinator whose agent is not running has nobody to tell: sessions_list says the state
    // once it starts again.
    guard launcher?.isRunning(coordinator) == true else { return }
    coordination.inbox.add(event, for: coordinator)
    startCoordinationTicker()
  }

  /// Reads the wake-ups kept, and starts telling them.
  func startCoordination() async {
    await coordination.load()
    if !coordination.wakes.isEmpty { startCoordinationTicker() }
  }

  /// Ticks every second while something waits to be typed, and otherwise wakes for the next
  /// wake-up, a minute at most later: a coordinator not running yet is looked at again.
  func startCoordinationTicker() {
    guard coordination.ticker == nil else { return }
    coordination.ticker = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.deliverCoordinationMessages()
        let coordination = self.coordination
        let hasMessages = !coordination.inbox.isEmpty || !coordination.outbox.isEmpty
        guard hasMessages || !coordination.wakes.isEmpty else {
          coordination.ticker = nil
          return
        }
        let nextWake =
          coordination.wakes.values.map(\.date).min()
          .map { max($0.timeIntervalSince(coordination.now()), 1) } ?? 60
        try? await Task.sleep(for: .seconds(hasMessages ? 1 : min(nextWake, 60)))
      }
    }
  }

  /// Whether a message can be typed into this session now: its agent runs, is at rest — not at
  /// work, where a dialog could open under the keys, nor waiting for the user —, shows no panel,
  /// and the user has not typed in its terminal for two seconds. An agent without hooks says
  /// nothing of what it does: it is taken to be at rest.
  func canTypeCoordinationMessage(into id: SessionID) async -> Bool {
    guard launcher?.isRunning(id) == true, !coordination.typing.contains(id) else { return false }
    switch activity(for: id)?.activity {
    case .working, .awaitingUser: return false
    case .idle, nil: break
    }
    if let typed = pane(for: id)?.lastKeyboardInputAt, ContinuousClock.now - typed < .seconds(2) {
      return false
    }
    if let screen = await launcher?.screen(of: id), AgentPanelRecognition.showsPanel(screen: screen)
    {
      return false
    }
    return true
  }

  /// Types a message into a session at rest, one at a time per session. Return is pressed only
  /// if the agent is still at rest once the text is in: it is never what answers a dialog.
  func typeCoordinationMessage(_ text: String, into id: SessionID) async -> Bool {
    guard await canTypeCoordinationMessage(into: id) else { return false }
    coordination.typing.insert(id)
    defer { coordination.typing.remove(id) }
    return await launcher?.typeMessage(text, into: id, whileWorking: false) { [weak self] in
      guard let self else { return false }
      switch self.activity(for: id)?.activity {
      case .working, .awaitingUser: return false
      case .idle, nil: return true
      }
    } ?? false
  }

  /// Tells each coordinator what waits for it, and gives each child the messages kept for it,
  /// when they can be written to.
  func deliverCoordinationMessages() async {
    let now = coordination.now()
    for (id, wake) in coordination.wakes where wake.date <= now {
      guard let coordinator = sessions.first(where: { $0.id == id }),
        coordinator.status != .archived
      else {
        coordination.setWake(nil, for: id)
        continue
      }
      // Kept until its coordinator runs: one due while the application was closed is told once
      // the agent is back.
      guard launcher?.isRunning(id) == true else { continue }
      coordination.setWake(nil, for: id)
      coordination.inbox.add(
        .wake(wake.reason, at: now.addingTimeInterval(-CoordinationInbox.quietPeriod)), for: id)
    }
    for id in coordination.inbox.due(at: now) {
      guard let coordinator = sessions.first(where: { $0.id == id }),
        coordinator.status != .archived, launcher?.isRunning(id) == true
      else {
        coordination.inbox.drop(id)
        continue
      }
      let events = coordination.inbox.events(for: id)
      guard !events.isEmpty,
        await typeCoordinationMessage(CoordinationInbox.message(for: events), into: id)
      else { continue }
      _ = coordination.inbox.take(for: id)
    }
    for (id, messages) in coordination.outbox {
      guard let text = messages.first else {
        coordination.outbox[id] = nil
        continue
      }
      guard sessions.contains(where: { $0.id == id && $0.status != .archived }),
        launcher?.isRunning(id) == true
      else {
        coordination.outbox[id] = nil
        continue
      }
      guard await typeCoordinationMessage(text, into: id) else { continue }
      let rest = Array((coordination.outbox[id] ?? []).dropFirst())
      coordination.outbox[id] = rest.isEmpty ? nil : rest
    }
  }
}

// MARK: - The tools

extension AppModel {
  /// Runs one of a coordinator's tools (#352). Every refusal is said to the agent, in English.
  func runCoordinationTool(_ tool: String, arguments: JSONValue, caller: SessionID) async
    -> BrowserToolResult
  {
    do {
      let coordinator = try CoordinationPolicy.coordinator(caller, among: sessions)
      switch tool {
      case "agents_list": return .text(await listAgents(for: coordinator))
      case "session_create": return .text(try await createChild(of: coordinator, arguments))
      case "sessions_list": return .text(listChildren(of: coordinator))
      case "session_read": return .text(try await readChild(of: coordinator, arguments))
      case "session_send": return .text(try await sendToChild(of: coordinator, arguments))
      case "session_set_status": return .text(try await moveChild(of: coordinator, arguments))
      case "session_close": return .text(try await closeChild(of: coordinator, arguments))
      case "wake_after": return .text(try wake(coordinator, arguments))
      case "notify_user": return .text(try callUser(for: coordinator, arguments))
      default: return .error("Unknown tool: \(tool)")
      }
    } catch let refusal as CoordinationRefusal {
      return .error(refusal.message)
    } catch {
      return .error(Self.message(for: error))
    }
  }

  private func listAgents(for coordinator: WorkSession) async -> String {
    guard let agents else { return "No agent is known to Vibe Manager." }
    let availabilities = await agents.availabilities()
    var lines: [String] = []
    for descriptor in await agents.descriptors()
    where availabilities[descriptor.id]?.state.isUsable == true {
      let models = await agents.provider(id: descriptor.id)?.models() ?? []
      let list =
        models.isEmpty
        ? "its own default model"
        : models.map { $0.isDefault ? "\($0.id) (default)" : $0.id }.joined(separator: ", ")
      lines.append("- \(descriptor.id.rawValue): \(descriptor.displayName); models: \(list)")
    }
    let limit = coordination.maximumRunningChildren
    lines.append(
      "\(runningChildren(of: coordinator.id)) of \(limit) children are running (the user's limit).")
    return lines.joined(separator: "\n")
  }

  private func createChild(of coordinator: WorkSession, _ arguments: JSONValue) async throws
    -> String
  {
    let name = try Self.string("name", in: arguments)
    let folder = (try Self.string("folder", in: arguments) as NSString).expandingTildeInPath
    let agent = try Self.string("agent", in: arguments)
    let mission = try Self.string("mission", in: arguments)
    let start = arguments["start"]?.boolValue ?? true
    var isDirectory: ObjCBool = false
    guard folder.hasPrefix("/"),
      FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw CoordinationRefusal.folderMissing(folder) }
    try CoordinationPolicy.checkFolder(folder, among: sessions) { launcher?.isRunning($0) == true }
    if start {
      try CoordinationPolicy.checkLimit(
        running: runningChildren(of: coordinator.id), limit: coordination.maximumRunningChildren)
      coordination.startingChildren[coordinator.id, default: 0] += 1
    }
    defer {
      if start { coordination.startingChildren[coordinator.id, default: 1] -= 1 }
    }
    guard let agents else { throw CoordinationRefusal.failed("No agent is known to Vibe Manager.") }
    let draft = SessionDraft(
      name: name,
      initialPrompt: CoordinationPolicy.fromCoordinator(mission, coordinatorName: coordinator.name),
      providerID: agent,
      modelID: arguments["model"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
      workingDirectoryPath: folder,
      ticketText: arguments["ticket"]?.stringValue ?? "",
      palette: appearancePalette.offered,
      coordination: .child(of: coordinator.id))
    let create = CreateSession(
      repository: repository, agents: agents, ticketContext: readTicketContext,
      icons: iconStore, diagnostics: diagnostics)
    let creation: SessionCreation
    do {
      creation = try await create(draft)
    } catch let rejected as SessionCreationRejected {
      throw CoordinationRefusal.invalidArgument(
        "The session could not be created: "
          + rejected.issues.map { $0.errorDescription ?? "\($0)" }.joined(separator: " "))
    }
    await publish(creation, launching: start, tracked: false, follows: false)
    let id = creation.session.id
    coordination.record(
      CoordinationTraceEntry(
        date: coordination.now(), coordinatorName: coordinator.name, action: .created,
        detail: CoordinationDigest.cut(mission, to: CoordinationTraceEntry.detailLimit)),
      for: id)
    diagnostics.record(
      .session, .info, "coordination.childCreated",
      ["session": diagnostics.pseudonym(id), "coordinator": diagnostics.pseudonym(coordinator.id)])
    let state =
      start
      ? (launcher?.isRunning(id) == true ? "Its agent is starting." : "Its agent could not start.")
      : "It waits in To Do."
    return "Created “\(creation.session.name)”, id \(id.rawValue.uuidString). \(state)"
  }

  private func listChildren(of coordinator: WorkSession) -> String {
    let children = children(of: coordinator.id)
    guard !children.isEmpty else { return "You have no child session yet." }
    let items: [JSONValue] = children.map { child in
      var item: [String: JSONValue] = [
        "id": .string(child.id.rawValue.uuidString),
        "name": .string(child.name),
        "status": .string(child.taskStatus.rawValue),
        "agent": .string(child.agent?.providerID ?? ""),
        "running": .bool(launcher?.isRunning(child.id) == true),
      ]
      if let model = child.agent?.modelID { item["model"] = .string(model) }
      if let folder = child.repositories.first?.path { item["folder"] = .string(folder) }
      if launcher?.isRunning(child.id) == true {
        item["agentState"] = .string(Self.state(of: activity(for: child.id)?.activity))
      }
      if let request = activity(for: child.id)?.requests.first {
        item["waitingFor"] = .string(CoordinationDigest.summary(of: request))
      }
      if let ticket = child.ticket?.url { item["ticket"] = .string(ticket.absoluteString) }
      if let branch = branch(of: child) { item["branch"] = .string(branch) }
      let pulls = pullRequests(of: child.id)
      if !pulls.isEmpty { item["pullRequests"] = .array(pulls.map { .string($0) }) }
      return .object(item)
    }
    return JSONValue.array(items).jsonText
  }

  private func readChild(of coordinator: WorkSession, _ arguments: JSONValue) async throws -> String
  {
    let child = try CoordinationPolicy.child(
      arguments["id"]?.stringValue, of: coordinator.id, among: sessions)
    let running = launcher?.isRunning(child.id) == true
    var parts = [
      "“\(child.name)” — status \(child.taskStatus.rawValue), agent "
        + (running ? Self.state(of: activity(for: child.id)?.activity) : "stopped") + "."
    ]
    if let request = activity(for: child.id)?.requests.first {
      parts.append("Waiting for the user: \(CoordinationDigest.summary(of: request))")
    }
    if let journal = journal?.journals.value(for: child.id) {
      let summary = journal.entries.suffix(5).map { "- \($0.text)" }
      if !summary.isEmpty { parts.append("Activity summary:\n" + summary.joined(separator: "\n")) }
      let resources = journal.resources.filter { $0.kind == .pullRequest || $0.kind == .branch }
        .map { "- \($0.kind.rawValue) \($0.label)" }
      if !resources.isEmpty { parts.append("Mentioned:\n" + resources.joined(separator: "\n")) }
    }
    let count = arguments["last"]?.intValue ?? CoordinationDigest.defaultEntryCount
    if let entries = await conversations.entries(of: child) {
      let budget = CoordinationDigest.readLimit - parts.joined(separator: "\n\n").count
      parts.append(
        "Last entries of its conversation:\n\n"
          + CoordinationDigest.transcript(entries, last: count, limit: max(budget, 1_000)))
    } else {
      parts.append("Its conversation cannot be read here; its terminal is the only view.")
    }
    return parts.joined(separator: "\n\n")
  }

  private func sendToChild(of coordinator: WorkSession, _ arguments: JSONValue) async throws
    -> String
  {
    let child = try CoordinationPolicy.child(
      arguments["id"]?.stringValue, of: coordinator.id, among: sessions)
    let text = try Self.string("text", in: arguments)
    // A child waiting for the user is refused: its request is the user's to answer.
    try CoordinationPolicy.checkSend(
      to: child, isRunning: launcher?.isRunning(child.id) == true,
      activity: activity(for: child.id)?.activity, showsPanel: false)
    let message = CoordinationPolicy.fromCoordinator(text, coordinatorName: coordinator.name)
    coordination.record(
      CoordinationTraceEntry(
        date: coordination.now(), coordinatorName: coordinator.name, action: .messaged,
        detail: CoordinationDigest.cut(text, to: CoordinationTraceEntry.detailLimit)),
      for: child.id)
    // Typed now only into a child at rest, and after the messages kept for it; otherwise kept,
    // and typed once it finishes its turn.
    if coordination.outbox[child.id] == nil,
      await typeCoordinationMessage(message, into: child.id)
    {
      return "Sent to “\(child.name)”."
    }
    coordination.outbox[child.id, default: []].append(message)
    startCoordinationTicker()
    return "“\(child.name)” is busy: the message will be typed once it finishes its turn."
  }

  private func moveChild(of coordinator: WorkSession, _ arguments: JSONValue) async throws
    -> String
  {
    let child = try CoordinationPolicy.child(
      arguments["id"]?.stringValue, of: coordinator.id, among: sessions)
    guard let raw = arguments["status"]?.stringValue,
      let status = SessionTaskStatus(rawValue: raw), status != .archived
    else {
      throw CoordinationRefusal.invalidArgument("status is one of todo, doing, waiting, done.")
    }
    let starts = Self.restartsWhenMoved(child, to: status) && canRestart(child)
    if starts {
      try CoordinationPolicy.checkLimit(
        running: runningChildren(of: coordinator.id), limit: coordination.maximumRunningChildren)
      if let folder = child.repositories.first?.path {
        try CoordinationPolicy.checkFolder(folder, among: sessions.filter { $0.id != child.id }) {
          launcher?.isRunning($0) == true
        }
      }
      coordination.startingChildren[coordinator.id, default: 0] += 1
    }
    defer {
      if starts { coordination.startingChildren[coordinator.id, default: 1] -= 1 }
    }
    if child.taskStatus != status {
      try await changeTaskStatus(id: child.id, to: status)
      await reload()
      coordination.record(
        CoordinationTraceEntry(
          date: coordination.now(), coordinatorName: coordinator.name, action: .movedTo(status)),
        for: child.id)
    }
    guard starts else { return "“\(child.name)” is now \(status.rawValue)." }
    let result = await restartInBatch(child.id)
    await reload()
    coordination.record(
      CoordinationTraceEntry(
        date: coordination.now(), coordinatorName: coordinator.name, action: .started),
      for: child.id)
    switch result {
    case .done, .doneWithWarning:
      return "“\(child.name)” is now \(status.rawValue), and its agent is starting."
    default:
      return
        "“\(child.name)” is now \(status.rawValue), but its agent was not started; the user can "
        + "start it."
    }
  }

  private func closeChild(of coordinator: WorkSession, _ arguments: JSONValue) async throws
    -> String
  {
    let child = try CoordinationPolicy.child(
      arguments["id"]?.stringValue, of: coordinator.id, among: sessions)
    guard launcher?.isRunning(child.id) == true else {
      return "The agent of “\(child.name)” is not running."
    }
    _ = await closeInBatch(child.id)
    await reload()
    coordination.record(
      CoordinationTraceEntry(
        date: coordination.now(), coordinatorName: coordinator.name, action: .closed),
      for: child.id)
    return "The agent of “\(child.name)” is stopped. The session stays in its column."
  }

  private func wake(_ coordinator: WorkSession, _ arguments: JSONValue) throws -> String {
    guard let minutes = arguments["minutes"]?.intValue, (1...240).contains(minutes) else {
      throw CoordinationRefusal.invalidArgument("minutes is a whole number from 1 to 240.")
    }
    let reason = try Self.string("reason", in: arguments)
    let date = coordination.now().addingTimeInterval(TimeInterval(minutes * 60))
    coordination.setWake(CoordinationWake(date: date, reason: reason), for: coordinator.id)
    startCoordinationTicker()
    return "Vibe Manager will write to you in \(minutes) minutes. End your turn now."
  }

  private func callUser(for coordinator: WorkSession, _ arguments: JSONValue) throws -> String {
    let message = try Self.string("message", in: arguments)
    // The user already looking at the coordinator reads the message there.
    guard !isOnScreen(coordinator.id) else { return "The user is looking at your session." }
    coordination.calls[coordinator.id] = message
    let safe = DisplaySafeText.visible(message)
    Announcer.announce(
      Self.announcement(state: safe, sessionName: coordinator.name), priority: .medium)
    let floats = floatingPanel?.isEnabled ?? false
    if !isApplicationActive, notifiesRequests, !floats, let notifier = requestNotifier {
      // What the agent wrote only when the user asked for the details of requests (#40).
      let body =
        requestNotificationContent == .detail
        ? safe
        : String(
          localized: "The coordinator needs you.", bundle: .module,
          comment: "The notification of a coordinator session that calls the user.")
      notifier.postOutcome(
        SessionOutcomeNotification(
          sessionID: coordinator.id, title: DisplaySafeText.visible(coordinator.name), body: body))
    }
    return "The user was called."
  }

  // MARK: Helpers

  private static func string(_ key: String, in arguments: JSONValue) throws -> String {
    guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { throw CoordinationRefusal.invalidArgument("\(key) is required.") }
    return value
  }

  private static func state(of activity: AgentActivity?) -> String {
    switch activity {
    case .working: return "working"
    case .awaitingUser: return "waiting for the user"
    case .idle, nil: return "idle"
    }
  }

  private func pullRequests(of id: SessionID) -> [String] {
    guard let journal = journal?.journals.value(for: id) else { return [] }
    return journal.resources.filter { $0.kind == .pullRequest }.map { resource in
      if case .web(let url) = resource.target { return url.absoluteString }
      return resource.label
    }
  }
}

// MARK: - Stopping a coordinator

/// A coordinator about to be closed or archived while children of its still run (#352).
public struct CoordinatorStop: Identifiable, Equatable, Sendable {
  public enum Action: Equatable, Sendable {
    case close
    case archive
  }

  public var id: SessionID { session.id }
  public let session: WorkSession
  public let action: Action
  public let runningChildren: Int
}

extension AppModel {
  /// Asks whether the children stop too, when a coordinator about to stop has some running.
  /// Whether it asked.
  func asksAboutChildren(of session: WorkSession, action: CoordinatorStop.Action) -> Bool {
    let running = runningChildren(ofCoordinator: session)
    guard !running.isEmpty else { return false }
    pendingCoordinatorStop = CoordinatorStop(
      session: session, action: action, runningChildren: running.count)
    return true
  }

  /// The user answered: the coordinator stops, and its children with it when `includingChildren`.
  /// The question stood for the usual one about stopping work in progress.
  public func confirmCoordinatorStop(_ stop: CoordinatorStop, includingChildren: Bool) async {
    pendingCoordinatorStop = nil
    if includingChildren { await closeChildren(of: stop.session.id) }
    switch stop.action {
    case .close: await close(stop.session.id)
    case .archive: await archive(stop.session.id)
    }
  }

  public func cancelCoordinatorStop() {
    pendingCoordinatorStop = nil
  }
}

// MARK: - The runner

/// Runs a coordinator's tools for the channel (#352), on the workspace it was given.
@MainActor
public final class CoordinationToolRunner: BrowserToolRunning {
  private weak var model: AppModel?

  public init(model: AppModel) {
    self.model = model
  }

  public func run(tool: String, arguments: JSONValue, session: SessionID) async
    -> BrowserToolResult
  {
    guard let model else { return .error(AgentToolServerDefinition.coordination.closedMessage) }
    return await model.runCoordinationTool(tool, arguments: arguments, caller: session)
  }

  /// The coordinators whose agent runs: the only sessions the coordination server lets in.
  public func coordinators() -> Set<SessionID> {
    Set(model?.sessions.filter { $0.coordination?.isCoordinator == true }.map(\.id) ?? [])
  }
}
