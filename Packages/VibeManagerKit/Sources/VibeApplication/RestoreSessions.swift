import Foundation
import VibeDomain

/// What a launch answered, as much of it as the application layer is allowed to know.
///
/// The panes, the terminals and their failures live in the interface; this is the shape of their
/// answer, so the restoration can report a failure without naming a type it cannot see.
public struct SessionRestartAttempt: Equatable, Sendable {
  public let started: Bool
  public let message: String?
  public let suggestion: String?

  public init(started: Bool, message: String? = nil, suggestion: String? = nil) {
    self.started = started
    self.message = message
    self.suggestion = suggestion
  }

  public static let started = SessionRestartAttempt(started: true)
}

/// Launching, seen as a port: the restoration asks for a process, it never makes one.
///
/// There is one object that knows what is already running, and it stays the only road to a
/// terminal. `SessionLauncher` conforms to this.
public protocol SessionRestarting: Sendable {
  @MainActor func isRunning(_ id: SessionID) -> Bool
  @MainActor func attemptRestart(_ restart: SessionRestart) async -> SessionRestartAttempt
}

/// Why a session the restoration walked past did not come back.
public enum SessionRestoreSkip: Equatable, Sendable {
  case alreadyRunning
  /// The agent's own conversation cannot be resumed, so restarting would mean sending a summary
  /// to an agent — and a summary is read before it is sent. Left to Restart, and to the user.
  case needsConfirmation(SessionRestartExplanation?)
  case refused(SessionRestartRefusal)
  case cancelled
}

public struct SessionRestoreOutcome: Equatable, Sendable {
  public enum Result: Equatable, Sendable {
    case restarted(SessionRestartMode)
    case skipped(SessionRestoreSkip)
    case failed(message: String, suggestion: String?)
  }

  public let sessionID: SessionID
  public let sessionName: String
  public let result: Result

  public init(sessionID: SessionID, sessionName: String, result: Result) {
    self.sessionID = sessionID
    self.sessionName = sessionName
    self.result = result
  }

  public var didRestart: Bool {
    if case .restarted = result { return true }
    return false
  }

  public var wasCancelled: Bool {
    result == .skipped(.cancelled)
  }

  /// What the report says about this session. `nil` when there is nothing worth a line: a session
  /// that came back, one that was already running, one the user called off themselves.
  public var sentence: String? {
    switch result {
    case .restarted, .skipped(.alreadyRunning), .skipped(.cancelled):
      return nil
    case .skipped(.needsConfirmation(let explanation)):
      return explanation?.sentence
        ?? "Starting this session again would send a prompt to its agent."
    case .skipped(.refused(let refusal)):
      return refusal.errorDescription ?? "This session could not be restarted."
    case .failed(let message, _):
      return message
    }
  }

  public var suggestion: String? {
    switch result {
    case .restarted, .skipped(.alreadyRunning), .skipped(.cancelled):
      return nil
    case .skipped(.needsConfirmation):
      return "Restart it to start a new process with a summary of the session."
    case .skipped(.refused(let refusal)):
      return refusal.recoverySuggestion
    case .failed(_, let suggestion):
      return suggestion
    }
  }
}

/// Where a restoration has got to, as it goes.
public enum SessionRestoreProgress: Equatable, Sendable {
  /// `index` is one-based: it is what the banner counts out loud.
  case started(sessionID: SessionID, sessionName: String, index: Int, total: Int)
  case finished(SessionRestoreOutcome)
}

/// Puts the sessions of an intention back to work, one at a time, and says so as it goes.
///
/// Sequential, deliberately. Each resume opens a pseudo terminal and starts a CLI that reads its
/// own configuration and history; five at once, on a cold disk, is an application that does not
/// answer during its own restoration. A queue is also the only shape that can be called off
/// between two items without stopping anything that is already running.
///
/// Nothing that would send a text is resumed — only a native resume, which sends nothing at all.
/// A summary handed to an agent at launch, with nobody having read it, is exactly what Restart
/// refuses to do quietly, and an initial prompt sent again days later is the same mistake with an
/// older instruction.
public struct RestoreSessions: Sendable {
  private let restart: RestartSession
  private let launcher: any SessionRestarting
  private let repository: any SessionRepository

  public init(
    restart: RestartSession,
    launcher: any SessionRestarting,
    repository: any SessionRepository
  ) {
    self.restart = restart
    self.launcher = launcher
    self.repository = repository
  }

  @discardableResult
  public func callAsFunction(
    _ intent: SessionRestoreIntent,
    onProgress: @escaping @MainActor @Sendable (SessionRestoreProgress) -> Void = { _ in }
  ) async -> [SessionRestoreOutcome] {
    var outcomes: [SessionRestoreOutcome] = []
    let total = intent.sessionIDs.count

    for (index, id) in intent.sessionIDs.enumerated() {
      let name = await name(of: id)

      // Cancellation is honoured between two sessions and nowhere else: a launch already under
      // way is finished, because stopping an agent that has just been handed its conversation
      // would destroy the very work this was restoring.
      if Task.isCancelled {
        let outcome = SessionRestoreOutcome(
          sessionID: id, sessionName: name, result: .skipped(.cancelled))
        outcomes.append(outcome)
        await onProgress(.finished(outcome))
        continue
      }

      await onProgress(
        .started(sessionID: id, sessionName: name, index: index + 1, total: total))
      let outcome = await restore(id: id, name: name)
      outcomes.append(outcome)
      await onProgress(.finished(outcome))
    }

    return outcomes
  }

  private func restore(id: SessionID, name: String) async -> SessionRestoreOutcome {
    func outcome(_ result: SessionRestoreOutcome.Result) -> SessionRestoreOutcome {
      SessionRestoreOutcome(sessionID: id, sessionName: name, result: result)
    }

    // The user may well have restarted it by hand while the queue was working through the list.
    if await launcher.isRunning(id) { return outcome(.skipped(.alreadyRunning)) }

    let plan: SessionRestart
    do {
      plan = try await restart(id: id)
    } catch let refusal as SessionRestartRefusal {
      return outcome(.skipped(.refused(refusal)))
    } catch is CancellationError {
      // Called off while the plan was being built. Reported as the cancellation it is: "the store
      // could not be read", with the remedy that goes with it, would be a sentence about a
      // failure that never happened.
      return outcome(.skipped(.cancelled))
    } catch {
      return outcome(.skipped(.refused(.storeUnreadable)))
    }

    // Only a resumed conversation runs unattended, because it is the only mode that sends
    // nothing. `needsConfirmation` alone was not that rule: `firstLaunch` confirms nothing either
    // and hands over the initial prompt.
    guard case .native = plan.mode else {
      return outcome(.skipped(.needsConfirmation(plan.explanation)))
    }

    let attempt = await launcher.attemptRestart(plan)
    guard attempt.started else {
      return outcome(
        .failed(
          message: attempt.message ?? "This session could not be restarted.",
          suggestion: attempt.suggestion
        )
      )
    }
    return outcome(.restarted(plan.mode))
  }

  /// The name is read for the report, and a session that has gone missing still gets a line:
  /// a report that silently drops what it could not do is a report nobody can act on.
  private func name(of id: SessionID) async -> String {
    guard let session = try? await repository.session(id: id) else { return "This session" }
    return session.name
  }
}
