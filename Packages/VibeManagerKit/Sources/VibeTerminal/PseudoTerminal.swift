import Darwin
import Foundation
import VibeApplication

// _IOW('t', 103, struct winsize): the ioctl request macros are not imported into Swift, so the
// encoding is reproduced here. 0x80000000 marks a write, 0x0008 is the size of `winsize`,
// 0x74 is the 't' group and 0x67 is request 103.
private let setWindowSizeRequest = UInt(0x8008_7467)

private func setWindowSize(_ size: TerminalSize, on descriptor: Int32) {
  guard size.isUsable else { return }
  var windowSize = winsize(
    ws_row: UInt16(clamping: size.rows),
    ws_col: UInt16(clamping: size.columns),
    ws_xpixel: 0,
    ws_ypixel: 0
  )
  _ = ioctl(descriptor, setWindowSizeRequest, &windowSize)
}

struct PseudoTerminal: Sendable {
  let masterDescriptor: Int32
  /// The parent's own descriptor on the slave, held until the session has read everything.
  ///
  /// A terminal that is nobody's controlling one throws its unread output away when its last
  /// descriptor closes. Whether the slave opened by the spawn's file actions becomes the child's
  /// controlling terminal is not something `posix_spawn` promises — no file action performs a
  /// `TIOCSCTTY` — and on the CI runner's macOS 15 a child that wrote its last lines and exited
  /// before the reader ran lost them: `exited(code: 0)`, and nothing on screen. Held open here, the
  /// slave is never closed by the child's exit, which instead waits for its output to be read.
  let slaveDescriptor: Int32
  let processIdentifier: pid_t

  // The child is a session leader, so its process group identifier equals its process
  // identifier and a signal sent to the group reaches the whole tree it spawned.
  var processGroupIdentifier: pid_t {
    processIdentifier
  }

  /// Resizes the terminal, and tells the child about it.
  ///
  /// Writing the new size is not enough. The kernel raises `SIGWINCH` on the terminal's
  /// foreground process group, and a process started by the application has none: measured on a
  /// running session, the agent reports no controlling terminal and a foreground group of 0,
  /// where a child spawned from a shell gets both. The size was therefore updated under a
  /// program nobody told to read it again, and the agent kept drawing at the width it started
  /// with. The signal is sent to the group the child leads, which does not depend on any of it.
  func resize(to size: TerminalSize) {
    guard size.isUsable else { return }
    setWindowSize(size, on: masterDescriptor)
    signalProcessGroup(SIGWINCH)
  }

  /// Called once the master has been drained: the terminal is now nobody's.
  func closeSlave() {
    close(slaveDescriptor)
  }

  @discardableResult
  func signalProcessGroup(_ signalNumber: Int32) -> Bool {
    kill(-processGroupIdentifier, signalNumber) == 0
  }
}

enum PseudoTerminalLauncher {
  static func launch(_ spec: TerminalSpec) throws -> PseudoTerminal {
    try validate(spec)

    let (master, slavePath) = try allocateMaster()

    do {
      // The reader never blocks a dispatch queue, and the descriptor must not survive into any
      // other process the application spawns.
      _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)
      _ = fcntl(master, F_SETFD, FD_CLOEXEC)

      // Darwin rejects window-size ioctls on a master whose slave has never been opened, and the
      // child must already see its size when it starts. The parent therefore opens the slave and
      // sizes the terminal — and keeps it open: see `PseudoTerminal.slaveDescriptor`.
      let slave = open(slavePath, O_RDWR | O_NOCTTY)
      guard slave >= 0 else {
        throw TerminalError.pseudoTerminalUnavailable(code: errno)
      }
      _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
      setWindowSize(spec.initialSize, on: slave)

      let processIdentifier: pid_t
      do {
        processIdentifier = try spawn(spec, slavePath: slavePath)
      } catch {
        close(slave)
        throw error
      }
      return PseudoTerminal(
        masterDescriptor: master, slaveDescriptor: slave, processIdentifier: processIdentifier)
    } catch {
      close(master)
      throw error
    }
  }

  // Allocating a pseudo terminal is a system-wide resource request: under pressure it fails
  // transiently, so a few attempts are made before the failure is reported to the user.
  private static func allocateMaster(attempts: Int = 3) throws -> (Int32, String) {
    var lastCode: Int32 = 0

    for attempt in 0..<attempts {
      errno = 0
      let master = posix_openpt(O_RDWR | O_NOCTTY)
      if master >= 0 {
        errno = 0
        if grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) {
          return (master, String(cString: name))
        }
        lastCode = errno
        close(master)
      } else {
        lastCode = errno
      }

      if attempt + 1 < attempts {
        usleep(20_000)
      }
    }

    // Some of these calls fail without setting errno; reporting a stale value would be worse
    // than reporting none.
    throw TerminalError.pseudoTerminalUnavailable(code: max(0, lastCode))
  }

  private static func validate(_ spec: TerminalSpec) throws {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false

    let workingDirectoryPath = spec.workingDirectoryURL.path
    guard
      fileManager.fileExists(atPath: workingDirectoryPath, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      // A failing chdir inside the child would surface as an opaque exit code instead of an
      // actionable message, so the directory is checked before spawning.
      throw TerminalError.workingDirectoryUnavailable(path: workingDirectoryPath)
    }

    let executablePath = spec.executableURL.path
    guard fileManager.fileExists(atPath: executablePath, isDirectory: &isDirectory) else {
      throw TerminalError.executableNotFound(path: executablePath)
    }
    guard !isDirectory.boolValue else {
      throw TerminalError.notExecutable(path: executablePath)
    }
    guard fileManager.isExecutableFile(atPath: executablePath) else {
      throw TerminalError.executableNotPermitted(path: executablePath)
    }
  }

  private static func spawn(_ spec: TerminalSpec, slavePath: String) throws -> pid_t {
    // The posix_spawn family returns its error code directly and leaves errno untouched, so the
    // returned value is the only meaningful diagnostic.
    var fileActions: posix_spawn_file_actions_t?
    let fileActionsResult = posix_spawn_file_actions_init(&fileActions)
    guard fileActionsResult == 0 else {
      throw TerminalError.spawnFailed(code: fileActionsResult)
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    try configureFileActions(&fileActions, spec: spec, slavePath: slavePath)

    var attributes: posix_spawnattr_t?
    let attributesResult = posix_spawnattr_init(&attributes)
    guard attributesResult == 0 else {
      throw TerminalError.spawnFailed(code: attributesResult)
    }
    defer { posix_spawnattr_destroy(&attributes) }

    var defaultedSignals = sigset_t()
    sigfillset(&defaultedSignals)
    posix_spawnattr_setsigdefault(&attributes, &defaultedSignals)
    var unblockedSignals = sigset_t()
    sigemptyset(&unblockedSignals)
    posix_spawnattr_setsigmask(&attributes, &unblockedSignals)

    // SETSID makes the child a session leader. CLOEXEC_DEFAULT closes every inherited
    // descriptor that the file actions do not name, including the masters of other sessions.
    let flags =
      POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
      | POSIX_SPAWN_SETSIGMASK
    posix_spawnattr_setflags(&attributes, Int16(flags))

    let executablePath = spec.executableURL.path
    let arguments = [executablePath] + spec.arguments
    let environment = spec.environment.map { "\($0.key)=\($0.value)" }.sorted()

    var processIdentifier: pid_t = 0
    let result = withCStrings(arguments) { argv in
      withCStrings(environment) { envp in
        posix_spawn(&processIdentifier, executablePath, &fileActions, &attributes, argv, envp)
      }
    }

    guard result == 0 else {
      throw launchError(forSpawnResult: result, executablePath: executablePath)
    }
    return processIdentifier
  }

  // An incomplete action list would start the child with no standard descriptors at all, under
  // POSIX_SPAWN_CLOEXEC_DEFAULT, and it would die with an opaque status instead of a usable error.
  // Every action is checked.
  private static func configureFileActions(
    _ fileActions: inout posix_spawn_file_actions_t?,
    spec: TerminalSpec,
    slavePath: String
  ) throws {
    // Opening the slave by path, without O_NOCTTY, inside a brand new session makes it the
    // controlling terminal of the child. Duplicating an inherited descriptor would not.
    let openResult = posix_spawn_file_actions_addopen(&fileActions, 0, slavePath, O_RDWR, 0)
    guard openResult == 0 else {
      throw TerminalError.pseudoTerminalUnavailable(code: openResult)
    }

    for descriptor in Int32(1)...Int32(2) {
      let duplicateResult = posix_spawn_file_actions_adddup2(&fileActions, 0, descriptor)
      guard duplicateResult == 0 else {
        throw TerminalError.pseudoTerminalUnavailable(code: duplicateResult)
      }
    }

    let workingDirectoryPath = spec.workingDirectoryURL.path
    let chdirResult = posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectoryPath)
    guard chdirResult == 0 else {
      throw TerminalError.workingDirectoryUnavailable(path: workingDirectoryPath)
    }
  }

  // posix_spawn reports the failure of the exec itself, so a missing or unrunnable binary is
  // distinguishable from a process that started and exited immediately.
  private static func launchError(
    forSpawnResult result: Int32,
    executablePath: String
  ) -> TerminalError {
    switch result {
    case ENOENT:
      return .executableNotFound(path: executablePath)
    case EACCES, EPERM:
      return .executableNotPermitted(path: executablePath)
    case ENOEXEC:
      return .notExecutable(path: executablePath)
    case EAGAIN, ENOMEM:
      return .resourceLimitReached(code: result)
    default:
      return .spawnFailed(code: result)
    }
  }

  private static func withCStrings<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result
  ) -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer {
      for pointer in pointers {
        free(pointer)
      }
    }
    return pointers.withUnsafeMutableBufferPointer { buffer in
      body(buffer.baseAddress)
    }
  }
}
