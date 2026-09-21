import Foundation
import Observation
import VibeApplication
import VibeDomain

@MainActor
@Observable
public final class TerminalPaneModel {
  public enum Status: Equatable {
    case starting
    case running
    case exited(code: Int32)
    case terminated(signal: Int32)
    case failed(message: String)
  }

  public struct Failure: Equatable {
    public let message: String
    public let suggestion: String?
  }

  public private(set) var status: Status = .starting
  public private(set) var session: (any TerminalSession)?
  public private(set) var failure: Failure?

  private let sessionID: SessionID
  private let supervisor: any TerminalSupervisor
  private let spec: TerminalSpec
  private var stateTask: Task<Void, Never>?
  private var isStarting = false

  public init(sessionID: SessionID, supervisor: any TerminalSupervisor, spec: TerminalSpec) {
    self.sessionID = sessionID
    self.supervisor = supervisor
    self.spec = spec
  }

  // A pane whose process has finished can be started again: the guard keys on whether a session is
  // still running, not on whether one was ever created.
  public func start() async {
    guard !isStarting, session == nil || !status.isRunning else { return }
    isStarting = true
    defer { isStarting = false }

    stateTask?.cancel()
    stateTask = nil
    session = nil
    status = .starting
    failure = nil
    do {
      let session = try await supervisor.start(spec, for: sessionID)
      self.session = session
      observe(session)
    } catch let error as TerminalError {
      // The presented text stays free of technical detail; the errno lives in the diagnostic.
      failure = Failure(
        message: error.errorDescription ?? "The terminal could not be started.",
        suggestion: error.recoverySuggestion
      )
      status = .failed(message: error.errorDescription ?? "The terminal could not be started.")
    } catch {
      failure = Failure(message: "The terminal could not be started.", suggestion: nil)
      status = .failed(message: "The terminal could not be started.")
    }
  }

  public func stop() async {
    await supervisor.stop(id: sessionID, gracePeriod: .seconds(3))
    // The supervisor has dropped the session; make sure the pane reports the outcome even if the
    // final state change never reached the event stream.
    if let session {
      apply(await session.state())
    }
  }

  private func observe(_ session: any TerminalSession) {
    stateTask?.cancel()
    stateTask = Task { [weak self] in
      let attachment = await session.attach()
      self?.apply(attachment.state)
      for await event in attachment.events {
        guard case .stateChanged(let state) = event else { continue }
        self?.apply(state)
      }
      // The stream ends when the session finalises, and a stalled subscriber may have missed the
      // last state change, so read the settled state rather than trusting the events alone.
      guard !Task.isCancelled else { return }
      self?.apply(await session.state())
    }
  }

  private func apply(_ state: TerminalProcessState) {
    switch state {
    case .starting:
      status = .starting
    case .running:
      status = .running
    case .exited(let code):
      status = .exited(code: code)
    case .terminated(let signal):
      status = .terminated(signal: signal)
    case .failed(let error):
      status = .failed(message: error.errorDescription ?? "The terminal failed.")
    }
  }
}
