import Foundation
import VibeApplication

/// The command every activity hook runs, whatever the CLI (#45).
///
/// Written out in full rather than shipped as a script: nothing to install, and nothing that
/// breaks when the application is moved or updated while an agent runs. It appends one line to
/// the file named by `VIBE_AGENT_ACTIVITY_LOG` and returns at once — never a word on its output,
/// which a CLI could read as a decision taken in the user's place, and always success.
public enum AgentActivityHookCommand {
  public static let environmentKey = "VIBE_AGENT_ACTIVITY_LOG"
  /// Seconds a CLI waits for the hook. Appending a line takes milliseconds.
  public static let timeoutSeconds = 5
  /// The most of a hook's input kept on its line.
  public static let payloadByteLimit = 16 * 1024

  /// How much of what the CLI hands the hook ends up on the line.
  public enum Payload: Hashable, Sendable {
    /// Nothing: the prompt a user typed, or a tool's whole output, has no business on disk.
    case drop
    /// The input, cut at `payloadByteLimit` — for the questions #40 will show.
    case keep
    /// Only whether the input contains this text, written back when it does.
    case match(String)
    /// Only these string fields, each the first of its name, written back as a JSON object of
    /// their own. Read from the first `payloadByteLimit` bytes, which hold the fields that come
    /// before a tool's output: which agent ran which tool, on which command or file (#40).
    case fields([String])
  }

  /// The script, identical for every hook. Its input is read to the end in every case, so the CLI
  /// writing it never meets a closed pipe.
  static let script =
    #"f="$VIBE_AGENT_ACTIVITY_LOG"; "#
    + #"case "$2" in "#
    + #"keep) p=$({ head -c \#(payloadByteLimit); cat >/dev/null; } | tr -d "\r\n");; "#
    + #"match) p=$({ head -c \#(payloadByteLimit); cat >/dev/null; } | tr -d "\r\n" | grep -o -F -- "$3" | head -n 1);; "#
    + #"*) cat >/dev/null; p=;; "#
    + #"esac; "#
    + #"[ -n "$f" ] && printf "%s\t%s\t%s\n" "$1" "$(date +%s)" "$p" >>"$f"; "#
    + #"exit 0"#

  /// The script of `Payload.fields`. A script of its own rather than a branch of `script`, whose
  /// words Codex approved and must not see change. A value is a JSON string, escaped quotes
  /// included: `"command":"echo \"hi\""` is kept whole.
  static let fieldsScript =
    #"f="$VIBE_AGENT_ACTIVITY_LOG"; e="$1"; shift; "#
    + #"i=$({ head -c \#(payloadByteLimit); cat >/dev/null; } | tr -d "\r\n"); p=; "#
    + #"for k in "$@"; do "#
    + #"m=$(printf "%s" "$i" | grep -o -E -- "\"$k\": ?\"([^\"\\\\]|\\\\.)*\"" | head -n 1); "#
    + #"[ -n "$m" ] && p="${p:+$p,}$m"; done; "#
    + #"[ -n "$p" ] && p="{$p}"; "#
    + #"[ -n "$f" ] && printf "%s\t%s\t%s\n" "$e" "$(date +%s)" "$p" >>"$f"; "#
    + #"exit 0"#

  public static func command(event: String, payload: Payload) -> String {
    var script = self.script
    var arguments = [event]
    switch payload {
    case .drop: arguments.append("drop")
    case .keep: arguments.append("keep")
    case .match(let text): arguments += ["match", text]
    case .fields(let keys):
      script = fieldsScript
      arguments += keys
    }
    return (["/bin/sh", "-c", script, "vibe-activity"] + arguments).map(shellQuoted)
      .joined(separator: " ") + " 2>/dev/null"
  }

  /// Single quotes, the one quoting a POSIX shell never looks inside.
  static func shellQuoted(_ value: String) -> String {
    if !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || "/-_.".contains($0) }) {
      return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
  }
}

extension AgentLaunchPlan {
  /// The same plan with `options` placed before any `--`, where the CLI still reads options, and
  /// the log named in its environment.
  func reportingActivity(options: [String], to log: URL) -> AgentLaunchPlan {
    var arguments = self.arguments
    let separator = arguments.firstIndex(of: "--") ?? arguments.endIndex
    arguments.insert(contentsOf: options, at: separator)
    var environment = self.environment
    environment[AgentActivityHookCommand.environmentKey] = log.path
    return AgentLaunchPlan(
      providerID: providerID,
      executablePath: executablePath,
      arguments: arguments,
      environment: environment,
      workingDirectoryPath: workingDirectoryPath,
      promptDelivery: promptDelivery,
      version: version
    )
  }
}

extension AgentActivityEvent {
  /// The payload's top-level fields, when it is JSON — it may have been cut short.
  var jsonObject: [String: Any]? {
    guard let payload else { return nil }
    return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
  }

  func string(_ key: String) -> String? {
    jsonObject?[key] as? String
  }
}
