import Foundation
import Testing

/// A lint, run as a test: every child the application starts goes through one of the launchers
/// `docs/security-review.md` lists, each with its process group, its descriptors closed, its
/// timeout and its guard. A new `Process()` or `posix_spawn` anywhere else fails here, before it
/// can leave an orphan behind.
@Suite("Process launch inventory")
struct ProcessLaunchInventoryTests {
  /// The only files allowed to start a process, and why.
  private static let launchers: Set<String> = [
    // Probes, `git`, `xcode-select`: everything that is not a terminal.
    "Packages/VibeManagerKit/Sources/VibeProcess/BoundedProcess.swift",
    // A terminal: a session of its own, on a pseudo terminal.
    "Packages/VibeManagerKit/Sources/VibeTerminal/PseudoTerminal.swift",
    // The terminal host, the application's own binary in a session of its own.
    "Packages/VibeManagerKit/Sources/VibeTerminal/TerminalHost.swift",
  ]

  /// Each a whole identifier followed by its call: `reapProcess()` is not `Process()`.
  private static let forbidden = [
    "Process", "posix_spawn", "posix_spawnp", "NSTask", "system", "popen", "fork", "vfork",
    "execv", "execve", "execvp",
  ]

  private static let pattern = try! NSRegularExpression(
    pattern: "(?<![A-Za-z0-9_.])(" + forbidden.joined(separator: "|") + ")\\s*\\(")

  private static func calls(in code: String) -> [String] {
    let range = NSRange(code.startIndex..., in: code)
    return pattern.matches(in: code, range: range).compactMap { match in
      Range(match.range(at: 1), in: code).map { String(code[$0]) }
    }
  }

  private static var repositoryRoot: URL {
    var url = URL(fileURLWithPath: #filePath)
    // Tests/VibeProcessTests/<file> → Packages/VibeManagerKit → repository.
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }

  private static func swiftSources(under relativePath: String) -> [String] {
    let root = repositoryRoot.appendingPathComponent(relativePath)
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil)
    else { return [] }
    return enumerator.compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" }
      .map { String($0.standardizedFileURL.path.dropFirst(repositoryRoot.path.count + 1)) }
  }

  @Test("No production source starts a process outside the listed launchers")
  func inventory() throws {
    let sources =
      Self.swiftSources(under: "Packages/VibeManagerKit/Sources")
      + Self.swiftSources(under: "App")
    try #require(sources.count > 50, "The sources were not found from \(#filePath)")

    var offenders: [String] = []
    for path in sources where !Self.launchers.contains(path) {
      let text = try String(
        contentsOf: Self.repositoryRoot.appendingPathComponent(path), encoding: .utf8)
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let code = line.split(separator: "//", maxSplits: 1).first.map(String.init) ?? ""
        for name in Self.calls(in: code) {
          offenders.append("\(path):\(number + 1): \(name)")
        }
      }
    }
    #expect(offenders.isEmpty, "Start processes through BoundedProcess: \(offenders)")
  }

  @Test("The lint recognises a call, and only a call")
  func recognisesCalls() {
    #expect(Self.calls(in: "let process = Process()") == ["Process"])
    #expect(Self.calls(in: "posix_spawn(&pid, path, nil, nil, argv, envp)") == ["posix_spawn"])
    #expect(Self.calls(in: "await reapProcess()").isEmpty)
    #expect(Self.calls(in: "FileSystem(), self.system(x)").isEmpty)
  }

  @Test("Every listed launcher still exists")
  func launchersExist() {
    for path in Self.launchers {
      #expect(
        FileManager.default.fileExists(
          atPath: Self.repositoryRoot.appendingPathComponent(path).path), "\(path)")
    }
  }
}
