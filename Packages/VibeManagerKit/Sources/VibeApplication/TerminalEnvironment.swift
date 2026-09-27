import Foundation

public enum TerminalEnvironment {
  // Inheriting the whole environment of a Finder-launched application leaks variables the user
  // never chose into every agent process, so the inherited part is an explicit allowlist.
  public static let inheritedKeys: Set<String> = [
    "HOME",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "LOGNAME",
    "PATH",
    "SHELL",
    "SSH_AUTH_SOCK",
    "TMPDIR",
    "TZ",
    "USER",
  ]

  public static let fallbackPath = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  // A terminal without these is a degraded terminal: programs fall back to monochrome output
  // and ASCII-only rendering. They describe the emulator drawing the output, so they are set
  // here rather than inherited: a Finder-launched application has no `TERM` at all, and one
  // launched from another terminal carries that terminal's.
  public static let capabilities: [String: String] = [
    "TERM": "xterm-256color",
    "COLORTERM": "truecolor",
    "TERM_PROGRAM": "VibeManager",
  ]

  public static func make(
    inheriting inherited: [String: String] = ProcessInfo.processInfo.environment,
    adding additions: [String: String] = [:]
  ) -> [String: String] {
    var environment = inherited.filter { inheritedKeys.contains($0.key) }

    environment.merge(capabilities) { _, capability in capability }
    environment = withLocale(environment)
    if environment["PATH"]?.isEmpty ?? true {
      environment["PATH"] = fallbackPath
    }

    for (key, value) in additions {
      environment[key] = value
    }
    return environment
  }

  /// Gives a UTF-8 locale to an environment that names none. An application opened from the Finder
  /// inherits no `LANG`: left so, the shell and the agent run in the `C` locale, and `pbcopy`
  /// reads what they copy as Mac Roman — « été » lands on the clipboard as « √©t√© ».
  public static func withLocale(_ environment: [String: String]) -> [String: String] {
    let named = ["LANG", "LC_ALL", "LC_CTYPE"].contains { !(environment[$0] ?? "").isEmpty }
    guard !named else { return environment }
    var environment = environment
    environment["LANG"] = "en_US.UTF-8"
    return environment
  }
}
