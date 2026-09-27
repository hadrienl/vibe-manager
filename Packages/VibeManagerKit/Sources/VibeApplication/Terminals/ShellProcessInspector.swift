import Foundation

/// What a shell in a side terminal is doing, seen from outside it (#43).
public struct ShellProcessSnapshot: Hashable, Sendable {
  /// The folder the shell is in.
  public let currentDirectory: String?
  /// The command running in the foreground of its terminal — `npm run dev`, `vim` — or `nil` when
  /// the shell is waiting at its prompt.
  public let foregroundCommand: String?

  public init(currentDirectory: String?, foregroundCommand: String?) {
    self.currentDirectory = currentDirectory
    self.foregroundCommand = foregroundCommand
  }
}

/// Reads a shell's folder and foreground command from the kernel.
///
/// Neither the terminal host nor its protocol is needed for that: the shell runs as the same user
/// on the same Mac, and its terminal's foreground process group is part of what the kernel says of
/// any process. Isolated so the drawer can be tested with shells that do not exist.
public protocol ShellProcessInspector: Sendable {
  /// `nil` when the process is gone, or is not one the kernel will describe.
  func inspect(processIdentifier: Int32) async -> ShellProcessSnapshot?
}

/// Says nothing of any shell: a workspace assembled without the system around it.
public struct NoShellInspection: ShellProcessInspector {
  public init() {}

  public func inspect(processIdentifier: Int32) async -> ShellProcessSnapshot? { nil }
}

/// Whether the side terminals' history is kept on disk (ADR 0030). On unless turned off.
@MainActor
public protocol TerminalPreferences: AnyObject {
  var keepsScrollback: Bool { get set }
}

/// Kept for this run only.
@MainActor
public final class InMemoryTerminalPreferences: TerminalPreferences {
  public var keepsScrollback: Bool

  public init(keepsScrollback: Bool = true) {
    self.keepsScrollback = keepsScrollback
  }
}
