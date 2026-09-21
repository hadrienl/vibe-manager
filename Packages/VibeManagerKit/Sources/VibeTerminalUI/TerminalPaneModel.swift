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

  public init(sessionID: SessionID, supervisor: any TerminalSupervisor, spec: TerminalSpec) {
    self.sessionID = sessionID
    self.supervisor = supervisor
    self.spec = spec
  }

  public func start() async {
    guard session == nil else { return }

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
