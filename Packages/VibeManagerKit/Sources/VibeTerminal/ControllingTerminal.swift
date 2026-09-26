import Darwin
import Foundation

/// Gives a side terminal's shell its terminal as its controlling terminal (#43).
///
/// `posix_spawn` makes the child a session leader and opens the terminal on its standard
/// descriptors, but on macOS opening a terminal does not make it the controlling one: only
/// `TIOCSCTTY`, from the child, does, and no spawn action performs it. Measured on a running
/// session, the child reports no terminal (`ps` shows `??`) and a foreground group of 0. An agent
/// in raw mode never notices; a shell does: without a controlling terminal it has no job control,
/// ⌃C interrupts nothing because the kernel has no foreground group to signal, and the command it
/// runs cannot be told from the shell itself.
///
/// So a side terminal's shell is started through this binary, as VS Code's terminals are started
/// through a helper of their own: `<binary> --terminal-exec <path> <argv0> <arguments…>` takes the
/// terminal — it is already a session leader, with the terminal on descriptor 0 — and `exec`s the
/// shell in the same process. An agent's terminal is started as it always was.
public enum ControllingTerminal {
  public static let argument = "--terminal-exec"

  /// `TIOCSCTTY`, `_IO('t', 97)`: a macro Swift does not import.
  private static let setControllingTerminalRequest: UInt = 0x2000_7461

  private final class Configuration: @unchecked Sendable {
    let lock = NSLock()
    var trampolinePath: String?
  }

  private static let configuration = Configuration()

  /// The binary that answers `--terminal-exec`: the application's own, in the application and in
  /// the terminal host. Unset, a side terminal is started like any other, without job control.
  public static func useTrampoline(at path: String?) {
    configuration.lock.withLock { configuration.trampolinePath = path }
  }

  static var trampolinePath: String? {
    configuration.lock.withLock { configuration.trampolinePath }
  }

  /// Becomes the program asked for, when the arguments ask for it; returns at once otherwise.
  ///
  /// Called first thing, before anything of the application is set up: the process it becomes
  /// keeps nothing of this one but its identifier, its session and its descriptors.
  public static func runIfRequested(arguments: [String] = CommandLine.arguments) {
    guard arguments.count >= 4, arguments[1] == argument else { return }
    let path = arguments[2]
    let argv = Array(arguments[3...])
    // Refused only if the terminal is already another session's, which a new session's terminal
    // is not; the shell then runs as before rather than not at all.
    _ = ioctl(0, setControllingTerminalRequest, 0)
    withCStrings(argv) { pointers in
      _ = execv(path, pointers)
    }
    let message = "vibe-manager: cannot run \(path): \(String(cString: strerror(errno)))\n"
    _ = message.withCString { write(2, $0, strlen($0)) }
    _exit(127)
  }

  /// The arguments that start `executablePath` through the trampoline, or `nil` when there is none.
  static func arguments(for executablePath: String, arguments: [String]) -> (String, [String])? {
    guard let trampoline = trampolinePath else { return nil }
    return (trampoline, [trampoline, argument, executablePath, executablePath] + arguments)
  }

  private static func withCStrings<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
  ) -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeMutableBufferPointer { buffer in
      guard let base = buffer.baseAddress else { preconditionFailure("never empty") }
      return body(base)
    }
  }
}
