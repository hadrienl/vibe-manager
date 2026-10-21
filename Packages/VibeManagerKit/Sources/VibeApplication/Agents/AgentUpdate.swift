import Foundation

/// A CLI updated on disk while one of its processes still runs the build it was started from
/// (#409).
///
/// Claude Code installs its updates while it runs and says `Restart to update`; Codex updates at
/// a start, and the sessions already open stay on the previous build without a word. Neither is
/// read off the screen: the build a process runs is the file the kernel loaded, and the build the
/// next start would get is the one its executable resolves to now.
public struct AgentUpdate: Hashable, Sendable {
  /// The version the process runs, read from its path: `2.1.299`. `nil` when the path says none.
  public let runningVersion: String?
  /// The version the next start would get: `2.1.303`.
  public let installedVersion: String?

  public init(runningVersion: String?, installedVersion: String?) {
    self.runningVersion = runningVersion
    self.installedVersion = installedVersion
  }

  /// The update between the file a process runs and the one its executable resolves to now, or
  /// `nil` when they are the same build — or when nothing says they are two builds of one CLI.
  ///
  /// Both paths are resolved, links followed. Two builds of one install differ only by their
  /// versions: `…/claude/versions/2.1.299` and `…/claude/versions/2.1.303`, Codex's
  /// `…/releases/0.162.1-aarch64-apple-darwin/bin/codex`, Homebrew's `…/Cellar/codex/0.162.1/…`.
  /// A process that runs another file altogether — `node`, for a CLI installed by npm — tells
  /// nothing here, and is never taken for an update: see `replaced(changedAt:startedAt:…)`.
  public static func between(running: String, installed: String) -> AgentUpdate? {
    let old = running.split(separator: "/", omittingEmptySubsequences: true)
    let new = installed.split(separator: "/", omittingEmptySubsequences: true)
    guard old.count == new.count, old != new else { return nil }
    let changed = zip(old, new).filter { $0 != $1 }
    guard changed.allSatisfy({ version(in: $0) != nil && version(in: $1) != nil }) else {
      return nil
    }
    guard let first = changed.first else { return nil }
    return AgentUpdate(runningVersion: version(in: first.0), installedVersion: version(in: first.1))
  }

  /// The update of a CLI replaced where it stands: npm's `cli.js`, which `node` runs, keeps its
  /// path from one version to the next. Its inode changed after the process started — when the
  /// file was written, not when it says it was modified: npm dates every file of a package 1985.
  ///
  /// - Parameters:
  ///   - changedAt: the `ctime` of the file the executable resolves to.
  ///   - startedAt: when the process started, as the kernel says.
  ///   - runningVersion: what the detection said before the file changed, when known.
  ///   - installedVersion: what it says now, once it has been run again.
  public static func replaced(
    changedAt: Date, startedAt: Date, runningVersion: String?, installedVersion: String?
  ) -> AgentUpdate? {
    // A file written as the process starts — the install that launched it — is its own build.
    guard changedAt > startedAt.addingTimeInterval(replacementMargin) else { return nil }
    return AgentUpdate(
      runningVersion: runningVersion,
      installedVersion: installedVersion == runningVersion ? nil : installedVersion)
  }

  static let replacementMargin: TimeInterval = 5

  /// The version a path component opens on: `0.162.1` of `0.162.1-aarch64-apple-darwin`.
  static func version(in component: Substring) -> String? {
    guard let match = component.prefixMatch(of: /v?(\d+(?:\.\d+)+)/) else { return nil }
    return String(match.output.1)
  }
}

/// Whether a session can have its agent restarted without anything being lost (#409): the same
/// answer for the button and for the automatic restart.
public enum AgentUpdateRestartReadiness {
  /// - Parameters:
  ///   - activity: the session's agent activity; `nil` when none is followed.
  ///   - screen: the terminal's screen, as `SessionLauncher.screen(of:)` reads it.
  ///   - runsSubagents: whether a sub-agent of the conversation still runs.
  public static func isReady(
    activity: AgentActivityState?,
    screen: String?,
    runsSubagents: Bool
  ) -> Bool {
    guard let activity, activity.activity == .idle, activity.requests.isEmpty, !runsSubagents
    else { return false }
    guard let screen, promptIsEmpty(screen: screen) else { return false }
    return !runsInBackground(screen: screen)
  }

  /// Whether the agent's prompt is drawn, and empty. A prompt that cannot be read is not taken
  /// for an empty one: what the user typed into it would go with the process.
  public static func promptIsEmpty(screen: String) -> Bool {
    if let input = PromptInputRecognition.input(screen: screen) {
      return !PromptInputRecognition.holdsText(input)
    }
    // Codex draws no rules: its prompt is the last line opening on `›`, and shows one of its
    // hints while empty.
    let lines = screen.components(separatedBy: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard let prompt = lines.last(where: { $0.hasPrefix("›") }) else { return false }
    let text = prompt.dropFirst().trimmingCharacters(in: .whitespaces)
    return text.isEmpty || codexHints.contains(text)
  }

  /// What Codex 0.162 shows in its empty prompt: before the first turn, and after one.
  static let codexHints: Set<String> = ["Ask Codex to do anything", "Ask a follow-up question"]

  /// Whether the footer under the prompt counts work going on behind it — Claude Code's
  /// `▶▶ auto mode on · 2 shells · ← 1 agent`. Only below the prompt's last rule: the same words
  /// in what an agent wrote above it are not a footer. Without a rule — Codex — its last lines.
  public static func runsInBackground(screen: String) -> Bool {
    let lines = screen.components(separatedBy: "\n")
    let footer =
      lines.lastIndex(where: PromptInputRecognition.isRule).map { lines[($0 + 1)...] }
      ?? lines.suffix(3)
    return footer.contains { line in
      line.contains(/\b\d+ (shells?|agents?|(background )?(tasks?|terminals?))\b/)
    }
  }
}
