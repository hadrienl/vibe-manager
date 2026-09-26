import Foundation

/// What putting a side terminal back looks like (#43), decided without a process.
///
/// A process cannot survive the application that ran it — or the host, after a restart of the
/// Mac — so a side terminal comes back as a **new** shell, in the folder it was in, under the
/// history it showed, with a dated line saying where the old output stops. Nothing is typed into
/// the new shell: no command is ever run again on the user's behalf.
public enum DrawerRestoration {
  /// Where a shell was opened instead of the folder asked for.
  public enum Fallback: Hashable, Sendable {
    /// The remembered folder is gone: the session's own folder was used.
    case sessionFolder(missing: String)
    /// The session's folder is gone too — a worktree removed — so the home folder was used.
    case home(missing: String)
  }

  /// Why a new shell starts under an older history.
  public enum Resumption: Hashable, Sendable {
    /// Brought back after the session was reopened, or the application relaunched.
    case resumed
    /// Started again from its tab, after its previous shell ended.
    case relaunched
  }

  /// The folder a shell is opened in: the one asked for when it can be entered, else the
  /// session's, else the home folder. Always somewhere: a terminal that would not open over a
  /// missing folder is a worse answer than one opened elsewhere, saying so.
  public static func directory(
    remembered: String?,
    sessionFolder: String?,
    home: String = NSHomeDirectory(),
    probe: any WorkingDirectoryProbe
  ) async -> (path: String, fallback: Fallback?) {
    if let remembered, !remembered.isEmpty, await probe.inspect(path: remembered) == .usable {
      return (remembered, nil)
    }
    let missing = remembered.flatMap { $0.isEmpty ? nil : $0 }
    if let sessionFolder, !sessionFolder.isEmpty,
      await probe.inspect(path: sessionFolder) == .usable
    {
      return (sessionFolder, missing.map { .sessionFolder(missing: $0) })
    }
    return (home, (missing ?? sessionFolder).map { .home(missing: $0) })
  }

  /// Puts back what a history can leave a terminal in and a new shell does not expect: the
  /// alternate screen of an editor that was open, a hidden cursor, a scrolling region, attributes,
  /// bracketed paste and application cursor keys. A history is cut wherever its buffer was
  /// trimmed, so it may well end in the middle of any of them.
  public static let softReset: [UInt8] = Array(
    "\u{1B}[?1049l\u{1B}[r\u{1B}[0m\u{1B}[?25h\u{1B}[?2004l\u{1B}[?1l".utf8)

  /// What is written into the terminal before the new shell's first byte: the history, the reset,
  /// the dated separator and, when the folder changed, why.
  public static func notice(
    scrollback: [UInt8]?,
    resumption: Resumption,
    at date: Date,
    fallback: Fallback?
  ) -> [UInt8] {
    var bytes = scrollback ?? []
    if !bytes.isEmpty {
      bytes += softReset
    }
    bytes += Array(separator(for: resumption, at: date).utf8)
    if let fallback {
      bytes += Array(line(fallbackMessage(fallback)).utf8)
    }
    return bytes
  }

  /// "── Resumed · 26 Sep 2026 at 09:12 · new shell ──", dim and on its own lines, like the line
  /// over a restarted agent.
  public static func separator(for resumption: Resumption, at date: Date) -> String {
    let stamp = date.formatted(date: .abbreviated, time: .shortened)
    let title: String
    switch resumption {
    case .resumed:
      title = String(
        localized: "separator.resumed", defaultValue: "Resumed", bundle: .module,
        comment:
          "The title of the line a side terminal shows above the shell that replaced the one it had before the session was closed or the application quit: a noun."
      )
    case .relaunched:
      title = String(
        localized: "separator.relaunched", defaultValue: "Restarted", bundle: .module,
        comment:
          "The title of the line a side terminal shows above a shell started again after the previous one ended: a noun."
      )
    }
    let what = String(
      localized: "new shell", bundle: .module,
      comment: "In the line a side terminal shows above a shell it started again: what it is.")
    return "\r\n\u{1B}[2m── \(title) · \(stamp) · \(what) ──\u{1B}[0m\r\n"
  }

  public static func fallbackMessage(_ fallback: Fallback) -> String {
    switch fallback {
    case .sessionFolder(let missing):
      let path = printable(missing)
      return String(
        localized: "\(path) no longer exists: opened in the session's folder.",
        bundle: .module, comment: "Written in a side terminal. The argument is a folder's path.")
    case .home(let missing):
      let path = printable(missing)
      return String(
        localized: "\(path) no longer exists: opened in your home folder.",
        bundle: .module, comment: "Written in a side terminal. The argument is a folder's path.")
    }
  }

  /// A path as it can be written into a terminal: a folder's name may hold an escape character or
  /// a bidirectional override, which the terminal would obey rather than show.
  static func printable(_ text: String) -> String {
    String(
      String.UnicodeScalarView(
        text.unicodeScalars.map { scalar in
          let isControl = scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
          let isBidirectional =
            (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
          return isControl || isBidirectional ? "?" : scalar
        }))
  }

  /// Why a new tab did not open in the session's folder, as it is written above its shell.
  public static func fallbackNotice(_ fallback: Fallback) -> [UInt8] {
    Array(line(fallbackMessage(fallback)).utf8)
  }

  private static func line(_ text: String) -> String {
    "\u{1B}[2m── \(text) ──\u{1B}[0m\r\n"
  }
}
