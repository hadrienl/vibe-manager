import Darwin
import Foundation
import VibeApplication

/// Reads a side terminal's shell from the kernel (#43): the folder it is in, and the command its
/// terminal runs in the foreground.
///
/// The shell leads the process group of its terminal. When it runs a command, that command's
/// group becomes the terminal's foreground group (`e_tpgid`); back at its prompt, the shell's own
/// group is. Nothing here needs the pseudo terminal's descriptor, which lives in the host.
public struct DarwinShellProcessInspector: ShellProcessInspector {
  public init() {}

  /// On a queue of its own: `proc_pidinfo` on a folder of a network volume that went away can
  /// block its thread, and a thread of the cooperative pool blocked that way starves everything.
  public func inspect(processIdentifier: Int32) async -> ShellProcessSnapshot? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: Self.inspectBlocking(processIdentifier))
      }
    }
  }

  static func inspectBlocking(_ processIdentifier: pid_t) -> ShellProcessSnapshot? {
    guard processIdentifier > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, &info, size) == size else {
      return nil
    }
    let foreground = pid_t(bitPattern: info.e_tpgid)
    let ownGroup = pid_t(bitPattern: info.pbi_pgid)
    var command: String?
    if foreground > 0, foreground != ownGroup {
      command = commandLine(of: foreground) ?? name(of: foreground)
    }
    return ShellProcessSnapshot(
      currentDirectory: currentDirectory(of: processIdentifier), foregroundCommand: command)
  }

  static func currentDirectory(of processIdentifier: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(processIdentifier, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
      return nil
    }
    let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
      let bytes = raw.prefix { $0 != 0 }
      return String(decoding: bytes, as: UTF8.self)
    }
    return path.isEmpty ? nil : path
  }

  static func name(of processIdentifier: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
    guard proc_name(processIdentifier, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let name = String(
      decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return name.isEmpty ? nil : name
  }

  /// The command as it was typed, near enough: `npm run dev` rather than `node`.
  static func commandLine(of processIdentifier: pid_t) -> String? {
    guard let arguments = arguments(of: processIdentifier), !arguments.isEmpty else { return nil }
    return CommandTitle.make(arguments)
  }

  /// `KERN_PROCARGS2`: the argument count, the executable's path, padding, then the arguments.
  static func arguments(of processIdentifier: pid_t) -> [String]? {
    var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, processIdentifier]
    var size = 0
    guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return nil
    }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard count > 0 else { return nil }
    var index = MemoryLayout<Int32>.size
    // The executable's path, then the NULs that pad it.
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }
    var arguments: [String] = []
    while index < size, arguments.count < Int(count) {
      let start = index
      while index < size, buffer[index] != 0 { index += 1 }
      arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
      index += 1
    }
    return arguments
  }
}

/// A short title for a command line, for a tab.
enum CommandTitle {
  /// Programs that run a script: the script is what the user asked for.
  static let interpreters: Set<String> = [
    "node", "python", "python3", "ruby", "perl", "php", "bash", "sh", "zsh", "deno", "bun",
  ]
  static let maximumLength = 40

  static func make(_ arguments: [String]) -> String? {
    var words = arguments
    guard let first = words.first else { return nil }
    words[0] = (first as NSString).lastPathComponent
    // `node /usr/local/bin/npm run dev` is `npm run dev`; `python3 -m http.server` stays as it is.
    if interpreters.contains(words[0]), words.count > 1, !words[1].hasPrefix("-") {
      words.removeFirst()
      words[0] = (words[0] as NSString).lastPathComponent
    }
    let title = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return nil }
    guard title.count > maximumLength else { return title }
    return String(title.prefix(maximumLength - 1)) + "…"
  }
}
