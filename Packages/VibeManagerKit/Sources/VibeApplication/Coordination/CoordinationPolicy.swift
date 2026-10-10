import Foundation
import VibeDomain

/// Why a coordinator's tool refused what it was asked (#352). Said to the agent, in English, so that
/// it can act on it or tell the user.
public enum CoordinationRefusal: Error, Equatable, Sendable {
  /// The caller is not a coordinator.
  case notCoordinator
  /// No child of the caller has this id — one that exists but is another's included.
  case unknownChild(String)
  case limitReached(running: Int, limit: Int)
  /// Another running session works in this folder.
  case folderInUse(path: String, sessionName: String)
  case folderMissing(String)
  /// The child waits for the user: a key typed now could answer its dialog.
  case childAwaitingUser(String)
  /// A panel of the child's CLI is open, which a message would be typed into.
  case childShowingPanel(String)
  case childNotRunning(String)
  case invalidArgument(String)
  /// Anything the application could not do, said as it said it.
  case failed(String)

  public var message: String {
    switch self {
    case .notCoordinator:
      return "This session is not a coordinator: only a coordinator session has children."
    case .unknownChild(let id):
      return "No child session has the id \(id). sessions_list gives your children's ids."
    case .limitReached(let running, let limit):
      return
        "\(running) of \(limit) children are running, the limit the user set. Create it with "
        + "start false, or wait until a child finishes and close it."
    case .folderInUse(let path, let name):
      return
        "The session “\(name)” is running in \(path). Give the child a folder of its own, such "
        + "as a git worktree."
    case .folderMissing(let path):
      return "There is no folder at \(path). Create it first."
    case .childAwaitingUser(let name):
      return
        "“\(name)” is waiting for the user to answer a permission or a question, which is the "
        + "user's to answer. Tell the user, then try again once it is answered."
    case .childShowingPanel(let name):
      return
        "A panel of “\(name)”'s agent is open in its terminal. Try again once it is closed."
    case .childNotRunning(let name):
      return
        "The agent of “\(name)” is not running. Start it with session_set_status doing first."
    case .invalidArgument(let detail):
      return detail
    case .failed(let detail):
      return detail
    }
  }
}

/// The rules every tool of a coordinator follows (#352): whose children it may touch, how many may
/// run, where, and when a child may be written to. Pure: what runs and what the agents do is given.
public enum CoordinationPolicy {
  /// The caller, if it is a coordinator.
  public static func coordinator(_ id: SessionID, among sessions: [WorkSession]) throws
    -> WorkSession
  {
    guard let session = sessions.first(where: { $0.id == id }),
      session.coordination?.isCoordinator == true
    else { throw CoordinationRefusal.notCoordinator }
    return session
  }

  /// A coordinator's children, archived ones aside, in the order the store keeps them.
  public static func children(of id: SessionID, among sessions: [WorkSession]) -> [WorkSession] {
    sessions.filter { $0.coordination?.coordinatorID == id && $0.status != .archived }
  }

  /// The child an id names. A session that is not the caller's child — another coordinator's, an
  /// ordinary one, an archived one — is answered exactly as an id that names nothing.
  public static func child(
    _ text: String?, of coordinator: SessionID, among sessions: [WorkSession]
  ) throws -> WorkSession {
    let text = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let uuid = UUID(uuidString: text),
      let child = children(of: coordinator, among: sessions).first(where: {
        $0.id.rawValue == uuid
      })
    else { throw CoordinationRefusal.unknownChild(text) }
    return child
  }

  /// Refuses one more running child past the limit.
  public static func checkLimit(running: Int, limit: Int) throws {
    guard running < max(limit, 1) else {
      throw CoordinationRefusal.limitReached(running: running, limit: max(limit, 1))
    }
  }

  /// Refuses a folder another running session works in: two tasks in parallel must not write over
  /// each other. Compared once resolved, so that `~/x/` and `/Users/me/x` are one folder.
  public static func checkFolder(
    _ path: String, among sessions: [WorkSession], isRunning: (SessionID) -> Bool
  ) throws {
    let folder = standardized(path)
    for session in sessions where isRunning(session.id) {
      guard let other = session.repositories.first?.path, standardized(other) == folder else {
        continue
      }
      throw CoordinationRefusal.folderInUse(path: path, sessionName: session.name)
    }
  }

  /// Refuses to type into a child that is not running, waits for the user, or shows a panel of its
  /// CLI. The first rule of #352: a coordinator never answers a child's request in the user's place,
  /// and a key typed into a permission dialog could.
  public static func checkSend(
    to child: WorkSession, isRunning: Bool, activity: AgentActivity?, showsPanel: Bool
  ) throws {
    guard isRunning else { throw CoordinationRefusal.childNotRunning(child.name) }
    if case .awaitingUser = activity { throw CoordinationRefusal.childAwaitingUser(child.name) }
    guard !showsPanel else { throw CoordinationRefusal.childShowingPanel(child.name) }
  }

  /// The text a coordinator's message to a child is sent as: marked, so that the child — and the
  /// user reading its conversation — knows who wrote it.
  public static func fromCoordinator(_ text: String, coordinatorName: String) -> String {
    "[Coordinator “\(coordinatorName)”] " + text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func standardized(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    var standard = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    while standard.count > 1, standard.hasSuffix("/") { standard.removeLast() }
    return standard
  }
}
