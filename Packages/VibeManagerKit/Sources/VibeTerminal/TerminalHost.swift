import CryptoKit
import Darwin
import Dispatch
import Foundation
import VibeApplication
import os

/// Where one terminal host lives: a private directory holding its socket and its lock.
///
/// One per data directory rather than one per user: an isolated copy of the application
/// (`VIBE_DATA_DIRECTORY`) has its own store and its own runtime document, and so its own host. The
/// directory is in the per-user temporary folder, private to the user and short enough for the 104
/// bytes of `sun_path` — which `~/Library/Application Support` does not guarantee.
public struct TerminalHostLocation: Hashable, Sendable {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  /// The host of the application whose data lives in `dataDirectory`.
  public init(dataDirectory: URL) {
    let digest = SHA256.hash(data: Data(dataDirectory.standardizedFileURL.path.utf8))
    let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    directory = Self.userTemporaryDirectory()
      .appendingPathComponent("vibe-manager", isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
  }

  /// Named after the frozen core of the protocol: a host that spoke another one would listen
  /// elsewhere, and be drained rather than replaced.
  public var socketPath: String {
    directory.appendingPathComponent("host-v\(TerminalHostWire.protocolVersion).sock").path
  }

  /// The socket the application listens on for the agents' web view tools (#69). In the host's
  /// directory for its privacy and its short path; the application listens there, not the host.
  public var browserSocketPath: String {
    directory.appendingPathComponent("browser-v1.sock").path
  }

  var lockPath: String {
    directory.appendingPathComponent("host.lock").path
  }

  /// Written by a host told to stop — a logout, a shutdown, `kill` — as it goes. A host that
  /// crashes writes nothing, which is how the next launch tells the two apart.
  var stopRequestPath: String {
    directory.appendingPathComponent("stop-requested").path
  }

  /// When a host was last told to stop, if one said so.
  public func lastStopRequest() -> Date? {
    guard let data = FileManager.default.contents(atPath: stopRequestPath),
      let seconds = Double(String(decoding: data, as: UTF8.self))
    else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }

  func recordStopRequest(at date: Date = Date()) {
    let text = String(date.timeIntervalSince1970)
    FileManager.default.createFile(
      atPath: stopRequestPath, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
  }

  /// Creates the directory, private to the user.
  public func prepare() throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    chmod(directory.path, 0o700)
  }

  private static func userTemporaryDirectory() -> URL {
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
    if length > 0 {
      var buffer = [CChar](repeating: 0, count: length)
      if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
      }
    }
    return FileManager.default.temporaryDirectory
  }
}

/// The terminal host process: the application's own binary, started with `--terminal-host`.
public enum TerminalHost {
  public static let argument = "--terminal-host"
  private static let logger = Logger(
    subsystem: "eu.hadrien.VibeManager.terminal-host", category: "host")

  /// Runs the host and never returns, when the arguments ask for it; returns at once otherwise.
  ///
  /// Called before anything of the application is set up: in host mode there is no
  /// `NSApplication`, so no Dock icon, no menu bar and no window.
  public static func runIfRequested(
    arguments: [String] = CommandLine.arguments,
    verifier: @autoclosure () -> any TerminalHostPeerVerifier = CodeSigningPeerVerifier(),
    diagnostics: (URL) -> Diagnostics = { _ in .disabled }
  ) {
    guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else {
      return
    }
    let location = TerminalHostLocation(
      directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
    // Given by the application, never guessed: an isolated copy logs beside its own data.
    var log = Diagnostics.disabled
    if let logIndex = arguments.firstIndex(of: logDirectoryArgument),
      logIndex + 1 < arguments.count, arguments[logIndex + 1].hasPrefix("/")
    {
      log = diagnostics(URL(fileURLWithPath: arguments[logIndex + 1], isDirectory: true))
    }
    run(
      at: location,
      configuration: TerminalHostServer.Configuration(verifier: verifier(), diagnostics: log))
  }

  /// Followed by the folder the host writes `host.jsonl` in.
  public static let logDirectoryArgument = "--log-directory"

  public static func run(
    at location: TerminalHostLocation,
    configuration: TerminalHostServer.Configuration
  ) -> Never {
    signal(SIGPIPE, SIG_IGN)
    signal(SIGHUP, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let descriptors = raiseDescriptorLimit()
    let diagnostics = configuration.diagnostics

    do {
      try location.prepare()
    } catch {
      logger.error("The host directory could not be created.")
      exit(1)
    }

    // The lock comes before the socket: a host that cannot take it is a second one, and it leaves
    // without touching the socket the first one is listening on. It waits a little first — the
    // first one may be on its way out, idle, at the very moment the application asked for a host.
    let lock = open(location.lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    var isLocked = lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0
    let lockDeadline = ContinuousClock.now + .seconds(2)
    while lock >= 0, !isLocked, ContinuousClock.now < lockDeadline {
      usleep(50_000)
      isLocked = flock(lock, LOCK_EX | LOCK_NB) == 0
    }
    guard isLocked else {
      logger.info("Another terminal host holds the lock.")
      diagnostics.record(.host, .info, "host.alreadyRunning")
      diagnostics.flush()
      exit(0)
    }
    diagnostics.record(
      .host, .info, "host.started", ["descriptorLimit": .count(Int(clamping: descriptors))])
    // Whatever the previous host said about its end has been read by now: an application only
    // starts a host after it has looked for the one it left.
    unlink(location.stopRequestPath)
    // Held, the lock proves any socket left there belongs to a host that is gone.
    unlink(location.socketPath)
    let listener: Int32
    do {
      listener = try UnixSocket.listen(at: location.socketPath)
    } catch {
      logger.error("The host socket could not be bound.")
      exit(1)
    }

    let socketPath = location.socketPath
    let server = TerminalHostServer(configuration: configuration) {
      unlink(socketPath)
      exit(0)
    }

    let queue = DispatchQueue(label: "com.hadrienl.VibeManager.terminal-host.signals")
    let acceptSource = accept(on: listener, into: server)

    // Stopped on purpose — a logout, `kill`, the application stopping a host it cannot verify —
    // the host stops its agents first rather than leaving them without a terminal to write to.
    var signalSources: [any DispatchSourceSignal] = []
    for signalNumber in [SIGTERM, SIGINT] {
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
      source.setEventHandler {
        // Said first, before the agents are given their grace period: the system may not wait
        // for it, and the next launch must know this was not a crash.
        location.recordStopRequest()
        diagnostics.record(
          .host, .notice, "host.stopRequested", ["signal": .code(signalNumber)])
        // Nobody may attach to a host on its way out: an application relaunched meanwhile would
        // take back agents about to be stopped, and then lose them with this host. Gone from the
        // socket, it leaves room for the next host instead.
        unlink(socketPath)
        acceptSource.cancel()
        Task {
          await server.stopEverything()
          diagnostics.flush()
          exit(0)
        }
      }
      source.resume()
      signalSources.append(source)
    }

    Task { await server.begin() }
    withExtendedLifetime((acceptSource, signalSources, lock)) {
      dispatchMain()
    }
  }
}

extension TerminalHost {
  /// Descriptors the host asks for. Every session holds its master, its slave, a dispatch source
  /// and a client's share of the socket: launchd's soft limit of 256 runs out at a few dozen
  /// sessions, and the host would fail in the middle of serving the others.
  static let descriptorLimit: rlim_t = 4096

  /// Raises the soft limit on open descriptors to `descriptorLimit`, never beyond the hard one,
  /// and never lowers it. Returns the soft limit in force afterwards.
  @discardableResult
  static func raiseDescriptorLimit() -> rlim_t {
    var limit = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
    let wanted = min(limit.rlim_max, descriptorLimit)
    guard limit.rlim_cur < wanted else { return limit.rlim_cur }
    limit.rlim_cur = wanted
    guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else {
      getrlimit(RLIMIT_NOFILE, &limit)
      return limit.rlim_cur
    }
    return wanted
  }

  /// Hands every connection made to `listener` to `server`. The source is the only thing keeping
  /// the loop alive: cancelling it stops accepting, and closes the listener.
  static func accept(on listener: Int32, into server: TerminalHostServer) -> any DispatchSourceRead
  {
    _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL, 0) | O_NONBLOCK)
    let queue = DispatchQueue(label: "com.hadrienl.VibeManager.terminal-host.accept")
    let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
    source.setEventHandler {
      while true {
        let descriptor = Darwin.accept(listener, nil, nil)
        guard descriptor >= 0 else { return }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        Task { await server.accept(descriptor: descriptor) }
      }
    }
    source.setCancelHandler {
      close(listener)
    }
    source.resume()
    return source
  }
}

/// Starts a terminal host.
public protocol TerminalHostLaunching: Sendable {
  func launch(at location: TerminalHostLocation) throws
}

/// Starts the host from an executable that runs it when given `--terminal-host`.
///
/// Spawned, not registered with `launchd`: the host has no reason to exist before the application
/// first opens a terminal, nor after a restart, and an agent registered through `SMAppService`
/// costs a visible, revocable background item for neither.
public struct ExecutableTerminalHostLauncher: TerminalHostLaunching {
  private let executableURL: URL
  private let logDirectory: URL?
  private let disclaimsResponsibility: Bool

  /// - Parameter disclaimsResponsibility: `false` only for a test whose own sandbox refuses a child
  ///   that answers for itself; the application always disclaims (see `ResponsibilityDisclaimer`).
  public init(
    executableURL: URL, logDirectory: URL? = nil, disclaimsResponsibility: Bool = true
  ) {
    self.executableURL = executableURL
    self.logDirectory = logDirectory
    self.disclaimsResponsibility = disclaimsResponsibility
  }

  /// The application's own binary.
  public static func bundled(logDirectory: URL? = nil) -> ExecutableTerminalHostLauncher? {
    Bundle.main.executableURL.map {
      ExecutableTerminalHostLauncher(executableURL: $0, logDirectory: logDirectory)
    }
  }

  public func launch(at location: TerminalHostLocation) throws {
    try location.prepare()

    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    for descriptor in Int32(0)...Int32(2) {
      posix_spawn_file_actions_addopen(
        &fileActions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
    }

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaultedSignals = sigset_t()
    sigfillset(&defaultedSignals)
    posix_spawnattr_setsigdefault(&attributes, &defaultedSignals)
    var unblockedSignals = sigset_t()
    sigemptyset(&unblockedSignals)
    posix_spawnattr_setsigmask(&attributes, &unblockedSignals)
    // A session of its own and no controlling terminal: nothing the application's death sends to
    // its group or its terminal reaches the host.
    let flags =
      POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
      | POSIX_SPAWN_SETSIGMASK
    posix_spawnattr_setflags(&attributes, Int16(flags))
    if disclaimsResponsibility {
      ResponsibilityDisclaimer.apply(to: &attributes)
    }

    let path = executableURL.path
    var arguments = [path, TerminalHost.argument, location.directory.path]
    if let logDirectory {
      arguments += [TerminalHost.logDirectoryArgument, logDirectory.path]
    }
    let environment = Self.environment()
    var processIdentifier: pid_t = 0
    let result = withCStrings(arguments) { argv in
      withCStrings(environment) { envp in
        posix_spawn(&processIdentifier, path, &fileActions, &attributes, argv, envp)
      }
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    HostReaper.reap(processIdentifier)
  }

  /// The host needs almost nothing of the application's environment: every agent it starts is
  /// given the one the application computed for it (`TerminalSpec.environment`).
  private static func environment() -> [String] {
    let kept = ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "SHELL"]
    let current = ProcessInfo.processInfo.environment
    return kept.compactMap { key in current[key].map { "\(key)=\($0)" } }
  }
}

/// `responsibility_spawnattrs_setdisclaim`, looked up at run time.
///
/// A process macOS holds responsible for a child answers for it to TCC. Left alone, the host would
/// answer to the application — a pid that dies when the application quits, while the agents it
/// hosts carry on reading the user's folders. Disclaimed, the host answers for itself, and it is
/// the application's own signed binary: TCC sees Vibe Manager either way, and the Full Disk Access
/// granted to it goes on applying (ADR 0017). Private, and stable since macOS 10.14; looked up
/// rather than linked, so a system without it spawns the host as before instead of failing.
enum ResponsibilityDisclaimer {
  private typealias Function =
    @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) ->
    Int32

  static func apply(to attributes: inout posix_spawnattr_t?) {
    guard
      let symbol = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
    else { return }
    let function = unsafeBitCast(symbol, to: Function.self)
    _ = function(&attributes, 1)
  }
}

/// Collects the host's exit status while the application that spawned it is still alive, so it
/// never lingers as a zombie under it.
private enum HostReaper {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var sources: [pid_t: any DispatchSourceProcess] = [:]

  static func reap(_ processIdentifier: pid_t) {
    let source = DispatchSource.makeProcessSource(
      identifier: processIdentifier, eventMask: .exit, queue: .global(qos: .utility))
    source.setEventHandler {
      var status: Int32 = 0
      waitpid(processIdentifier, &status, WNOHANG)
      lock.withLock {
        sources[processIdentifier]?.cancel()
        sources[processIdentifier] = nil
      }
    }
    lock.withLock { sources[processIdentifier] = source }
    source.resume()
    // A host that ended before the source was watching raises no event at all.
    var status: Int32 = 0
    guard waitpid(processIdentifier, &status, WNOHANG) == processIdentifier else { return }
    lock.withLock {
      sources[processIdentifier]?.cancel()
      sources[processIdentifier] = nil
    }
  }
}

private func withCStrings<Result>(
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
