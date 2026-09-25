import Foundation
import VibeDomain

// The states worth logging, each reduced to a word of the source. A case that carries a path or a
// message is logged by its name alone; its numbers, when they help, go in fields of their own.

extension SessionStatus: DiagnosticTokenConvertible {}
extension AgentDetectionSource: DiagnosticTokenConvertible {}
extension SessionRuntimeState.Phase: DiagnosticTokenConvertible {}

extension AgentProviderID: DiagnosticTokenConvertible {
  /// Providers are code, not input — but an identifier read back from an old store could be
  /// anything, so only the ones this build knows are named.
  static let knownProviders: Set<String> = ["claude-code", "codex", "mock", "mock-b"]

  public var diagnosticToken: DiagnosticToken {
    switch rawValue {
    case "claude-code": return DiagnosticToken("claude-code")
    case "codex": return DiagnosticToken("codex")
    case "mock": return DiagnosticToken("mock")
    case "mock-b": return DiagnosticToken("mock-b")
    default: return DiagnosticToken("other")
    }
  }
}

extension AgentAvailabilityState: DiagnosticTokenConvertible {
  public var diagnosticToken: DiagnosticToken {
    switch self {
    case .available: return DiagnosticToken("available")
    case .outdated: return DiagnosticToken("outdated")
    case .notFound: return DiagnosticToken("notFound")
    case .notExecutable: return DiagnosticToken("notExecutable")
    case .unauthenticated: return DiagnosticToken("unauthenticated")
    case .probeFailed(.timedOut): return DiagnosticToken("probeTimedOut")
    case .probeFailed(.cancelled): return DiagnosticToken("probeCancelled")
    case .probeFailed(.failed): return DiagnosticToken("probeFailed")
    }
  }
}

extension TerminalError: DiagnosticTokenConvertible {
  public var diagnosticToken: DiagnosticToken {
    switch self {
    case .executableNotFound: return DiagnosticToken("executableNotFound")
    case .executableNotPermitted: return DiagnosticToken("executableNotPermitted")
    case .notExecutable: return DiagnosticToken("notExecutable")
    case .workingDirectoryUnavailable: return DiagnosticToken("workingDirectoryUnavailable")
    case .pseudoTerminalUnavailable: return DiagnosticToken("pseudoTerminalUnavailable")
    case .resourceLimitReached: return DiagnosticToken("resourceLimitReached")
    case .spawnFailed: return DiagnosticToken("spawnFailed")
    case .sessionAlreadyRunning: return DiagnosticToken("sessionAlreadyRunning")
    case .processOutcomeUnknown: return DiagnosticToken("processOutcomeUnknown")
    case .tooManySessions: return DiagnosticToken("tooManySessions")
    case .hostStopped: return DiagnosticToken("hostStopped")
    }
  }

  /// The number that goes with the error, when there is one.
  public var diagnosticCode: Int32? {
    switch self {
    case .pseudoTerminalUnavailable(let code), .resourceLimitReached(let code),
      .spawnFailed(let code):
      return code
    case .tooManySessions(let limit):
      return Int32(clamping: limit)
    case .executableNotFound, .executableNotPermitted, .notExecutable,
      .workingDirectoryUnavailable, .sessionAlreadyRunning, .processOutcomeUnknown, .hostStopped:
      return nil
    }
  }
}

extension TerminalProcessState: DiagnosticTokenConvertible {
  public var diagnosticToken: DiagnosticToken {
    switch self {
    case .starting: return DiagnosticToken("starting")
    case .running: return DiagnosticToken("running")
    case .exited: return DiagnosticToken("exited")
    case .terminated: return DiagnosticToken("terminated")
    case .failed: return DiagnosticToken("failed")
    }
  }

  /// The state's fields: the exit status, the signal or the error, never a path.
  public var diagnosticFields: [(name: StaticString, value: DiagnosticValue)] {
    switch self {
    case .starting, .running:
      return []
    case .exited(let code):
      return [("code", .code(code))]
    case .terminated(let signal):
      return [("signal", .code(signal))]
    case .failed(let error):
      var fields: [(name: StaticString, value: DiagnosticValue)] = [
        ("error", .token(error.diagnosticToken))
      ]
      if let code = error.diagnosticCode { fields.append(("errorCode", .code(code))) }
      return fields
    }
  }
}

extension PreviousShutdown: DiagnosticTokenConvertible {
  public var diagnosticToken: DiagnosticToken {
    switch self {
    case .nothingToDo: return DiagnosticToken("nothingToDo")
    case .clean: return DiagnosticToken("clean")
    case .unexpected: return DiagnosticToken("unexpected")
    case .otherInstance: return DiagnosticToken("otherInstance")
    case .detached: return DiagnosticToken("detached")
    case .hostUnavailable: return DiagnosticToken("hostUnavailable")
    }
  }
}

extension UsageRunKind: DiagnosticTokenConvertible {}

extension DiagnosticValue {
  /// The `errno` behind a Foundation error, when there is one: the one number of a file error
  /// that says what happened without saying to which file.
  public static func posixCode(of error: any Error) -> DiagnosticValue? {
    var current: NSError? = error as NSError
    while let error = current {
      if error.domain == NSPOSIXErrorDomain { return .code(Int32(clamping: error.code)) }
      current = error.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return nil
  }
}
extension QuitBehavior: DiagnosticTokenConvertible {}
