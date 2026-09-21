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

  public static func make(
    inheriting inherited: [String: String] = ProcessInfo.processInfo.environment,
    adding additions: [String: String] = [:]
  ) -> [String: String] {
    var environment = inherited.filter { inheritedKeys.contains($0.key) }

    // A terminal without these is a degraded terminal: programs fall back to monochrome output
    // and ASCII-only rendering.
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["TERM_PROGRAM"] = "VibeManager"
    if environment["LANG"] == nil, environment["LC_ALL"] == nil {
      environment["LANG"] = "en_US.UTF-8"
    }
    if environment["PATH"]?.isEmpty ?? true {
      environment["PATH"] = fallbackPath
    }

    for (key, value) in additions {
      environment[key] = value
    }
    return environment
  }
}
