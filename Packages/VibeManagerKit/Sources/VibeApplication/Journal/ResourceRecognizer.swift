import Foundation
import VibeDomain

/// A forge, as far as the journal tells them apart.
public enum Forge: String, Hashable, Sendable {
  case github
  case gitlab
}

/// A resource named by a transcript, as far as the transcript alone can tell (#36).
public enum ResourceSighting: Hashable, Sendable {
  /// Complete: a URL said everything.
  case resource(SessionResource)
  /// A number handed to `gh` or `glab`. `repository` when the command named one, otherwise the
  /// repository of `directory` is asked for its remote.
  case reference(
    Forge, SessionResource.Kind, number: Int, repository: String?, directory: String?,
    involvement: SessionResource.Involvement, at: Date)
  /// A branch of the repository `directory` is in.
  case branch(
    name: String, directory: String, involvement: SessionResource.Involvement, at: Date)
  case worktree(path: String, involvement: SessionResource.Involvement, at: Date)
}

/// Finds the tickets, requests, branches and worktrees a transcript names, without any network and
/// without any model: a table of rules, each tested on its own.
public enum ResourceRecognizer {
  // MARK: - Events

  /// Everything an event of the transcript names.
  public static func sightings(in event: TranscriptEvent, now: Date) -> [ResourceSighting] {
    switch event {
    case .prompt(let text, let at), .agentText(let text, let at):
      return urls(in: text, involvement: .viewed, at: at ?? now).map { .resource($0) }
    case .toolCall(let call):
      let at = call.at ?? now
      var found: [ResourceSighting] = []
      for text in call.strings {
        found += urls(in: text, involvement: .viewed, at: at).map { .resource($0) }
      }
      if let command = call.command {
        found += commandSightings(
          command, directory: call.directory, branch: call.branch, at: at)
      }
      if let directory = call.directory, let worktree = worktree(containing: directory) {
        found.append(.worktree(path: worktree, involvement: .changed, at: at))
      }
      return found
    case .creationOutput(let command, let directory, let output, let at):
      return outputSightings(command, directory: directory, output: output, at: at ?? now)
    case .turnEnded:
      return []
    }
  }

  // MARK: - URLs

  private static let urlPattern = try? NSRegularExpression(
    pattern: #"https?://[A-Za-z0-9.\-]+(?::[0-9]+)?/[^\s<>"'`\\\[\]{}|^]*"#)

  /// The tickets and requests a text links to, each once, in order.
  public static func urls(
    in text: String, involvement: SessionResource.Involvement, at: Date
  ) -> [SessionResource] {
    guard text.contains("http"), let urlPattern else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    var found: [SessionResource] = []
    var keys: Set<String> = []
    for match in urlPattern.matches(in: text, range: range) {
      guard let captured = Range(match.range, in: text) else { continue }
      let candidate = trimmed(String(text[captured]))
      guard let url = URL(string: candidate),
        let resource = resource(for: url, involvement: involvement, at: at),
        keys.insert(resource.key).inserted
      else { continue }
      found.append(resource)
    }
    return found
  }

  /// A URL's final punctuation belongs to the sentence around it: `…/pull/62).`
  static func trimmed(_ candidate: String) -> String {
    var text = candidate
    while let last = text.last {
      if ".,;:!?*_~".contains(last) {
        text.removeLast()
      } else if last == ")",
        text.filter({ $0 == "(" }).count < text.filter({ $0 == ")" }).count
      {
        text.removeLast()
      } else {
        break
      }
    }
    return text
  }

  /// The ticket or request a URL points to, whatever page of it: `/files`, `#note_12`, `?w=1`.
  public static func resource(
    for url: URL, involvement: SessionResource.Involvement, at: Date
  ) -> SessionResource? {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      var host = url.host?.lowercased(), !host.isEmpty
    else { return nil }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    if let port = url.port, port != 443, port != 80 { host += ":\(port)" }
    let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }

    // GitLab: `<group>/…/<project>/-/(issues|merge_requests|work_items)/<n>`, the `/-/` decisive.
    if let separator = components.firstIndex(of: "-") {
      let project = components[..<separator]
      let rest = Array(components[(separator + 1)...])
      guard project.count >= 2, rest.count >= 2, let number = Int(rest[1]), number > 0 else {
        return nil
      }
      let path = project.joined(separator: "/")
      let isRequest: Bool
      switch rest[0] {
      case "issues", "work_items": isRequest = false
      case "merge_requests": isRequest = true
      default: return nil
      }
      let page = isRequest ? "merge_requests" : "issues"
      guard let target = URL(string: "https://\(host)/\(path)/-/\(page)/\(number)") else {
        return nil
      }
      return SessionResource(
        key: "gitlab:\(host)/\(path.lowercased())#\(isRequest ? "mr" : "issue")/\(number)",
        kind: isRequest ? .pullRequest : .issue,
        label: isRequest ? "!\(number)" : "#\(number)",
        context: path,
        target: .web(target),
        involvement: involvement,
        firstSeenAt: at)
    }

    // GitHub, github.com or Enterprise: `<owner>/<repo>/(issues|pull)/<n>`. The shape is enough.
    guard components.count >= 4, let number = Int(components[3]), number > 0 else { return nil }
    let isRequest: Bool
    switch components[2] {
    case "issues": isRequest = false
    case "pull": isRequest = true
    default: return nil
    }
    let path = "\(components[0])/\(components[1])"
    guard
      let target = URL(
        string: "https://\(host)/\(path)/\(isRequest ? "pull" : "issues")/\(number)")
    else { return nil }
    // Issues and pull requests share their numbers: `/issues/62` of a pull request redirects to
    // it. One key for both, the more precise kind winning when they meet.
    return SessionResource(
      key: "github:\(host)/\(path.lowercased())#\(number)",
      kind: isRequest ? .pullRequest : .issue,
      label: "#\(number)",
      context: path,
      target: .web(target),
      involvement: involvement,
      firstSeenAt: at)
  }

  // MARK: - Commands

  /// What a command line names: its `gh`, `glab` and `git` commands, and its URLs.
  public static func commandSightings(
    _ line: String, directory: String?, branch: String?, at: Date
  ) -> [ResourceSighting] {
    // What a here-document holds is a file being written, not something the command uses.
    let line = withoutHereDocuments(line)
    var found: [ResourceSighting] = []
    var directory = directory
    // What the command does to what it names, for its URLs as well.
    var involvement = SessionResource.Involvement.viewed
    for words in ShellWords.commands(in: line) {
      guard let invocation = Invocation(words) else { continue }
      switch invocation.program {
      case "cd":
        // A `cd` whose folder is known moves the commands after it; one that is not stops the
        // guessing, since the folder they run in is no longer known.
        if let target = invocation.arguments.first {
          directory = target.flatMap { resolve($0, from: directory) }
        }
      case "gh", "glab":
        found += forgeSightings(invocation, directory: directory, at: at)
        if let verb = invocation.forgeVerb {
          involvement = max(involvement, forgeInvolvement(verb.action))
        }
      case "git":
        found += gitSightings(invocation, directory: directory, branch: branch, at: at)
      default:
        break
      }
    }
    // A URL on the command line: `curl`, `open`, a script's argument.
    found += urls(in: line, involvement: involvement, at: at).map { .resource($0) }
    return found
  }

  private static let hereDocumentPattern = try? NSRegularExpression(
    pattern: #"<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1"#)

  /// The command line without the bodies of its here-documents: `cat > f <<'EOF' … EOF`.
  static func withoutHereDocuments(_ line: String) -> String {
    guard line.contains("<<"), let hereDocumentPattern else { return line }
    var lines = line.components(separatedBy: "\n")
    var index = 0
    while index < lines.count {
      let current = lines[index]
      let range = NSRange(current.startIndex..., in: current)
      let delimiters = hereDocumentPattern.matches(in: current, range: range).compactMap {
        Range($0.range(at: 2), in: current).map { String(current[$0]) }
      }
      index += 1
      for delimiter in delimiters {
        // The body runs to the line that is the delimiter alone; one never closed runs to the end.
        let end =
          lines[index...].firstIndex {
            $0.trimmingCharacters(in: .whitespaces) == delimiter
          } ?? lines.count
        lines.removeSubrange(index..<min(end + 1, lines.count))
      }
    }
    return lines.joined(separator: "\n")
  }

  /// Whether what the command prints is worth reading: it creates a resource and prints it, or
  /// names one the command line did not.
  public static func readsOutput(of line: String) -> Bool {
    ShellWords.commands(in: line).contains { words in
      guard let invocation = Invocation(words),
        invocation.program == "gh" || invocation.program == "glab",
        let verb = invocation.forgeVerb
      else { return false }
      switch verb.action {
      case "create": return true
      case "checkout": return true
      case "view": return invocation.forgeNumber(after: verb) == nil
      default: return false
      }
    }
  }

  static func outputSightings(
    _ line: String, directory: String?, output: String, at: Date
  ) -> [ResourceSighting] {
    var found: [ResourceSighting] = []
    for words in ShellWords.commands(in: line) {
      guard let invocation = Invocation(words), let verb = invocation.forgeVerb else { continue }
      let involvement: SessionResource.Involvement =
        verb.action == "create" ? .created : verb.action == "view" ? .viewed : .changed
      found += urls(in: output, involvement: involvement, at: at).map { .resource($0) }
      if verb.action == "checkout", let directory,
        let name = checkedOutBranch(in: output)
      {
        found.append(.branch(name: name, directory: directory, involvement: .changed, at: at))
      }
    }
    return found
  }

  private static let switchedPattern = try? NSRegularExpression(
    pattern: #"Switched to (?:a new )?branch '([^']+)'"#)

  static func checkedOutBranch(in output: String) -> String? {
    guard let switchedPattern,
      let match = switchedPattern.firstMatch(
        in: output, range: NSRange(output.startIndex..., in: output)),
      let range = Range(match.range(at: 1), in: output)
    else { return nil }
    return String(output[range])
  }

  // MARK: gh and glab

  static func forgeSightings(
    _ invocation: Invocation, directory: String?, at: Date
  ) -> [ResourceSighting] {
    guard let verb = invocation.forgeVerb else { return [] }
    let forge: Forge = invocation.program == "gh" ? .github : .gitlab
    let kind: SessionResource.Kind = verb.noun == "issue" ? .issue : .pullRequest
    let involvement = forgeInvolvement(verb.action)
    guard let number = invocation.forgeNumber(after: verb) else { return [] }
    return [
      .reference(
        forge, kind, number: number, repository: invocation.option("-R", "--repo"),
        directory: directory, involvement: involvement, at: at)
    ]
  }

  static func forgeInvolvement(_ action: String) -> SessionResource.Involvement {
    switch action {
    case "create": return .created
    case "view", "diff", "checks", "status", "list": return .viewed
    default: return .changed
    }
  }

  // MARK: git

  static func gitSightings(
    _ invocation: Invocation, directory: String?, branch current: String?, at: Date
  ) -> [ResourceSighting] {
    var arguments = invocation.arguments
    var directory = directory
    // `git -C <dir> -c key=value <command>`
    while let first = arguments.first, let option = first, option.hasPrefix("-") {
      arguments.removeFirst()
      if option == "-C" {
        let target = arguments.first ?? nil
        directory = target.flatMap { resolve($0, from: directory) }
        if !arguments.isEmpty { arguments.removeFirst() }
      } else if option == "-c", !arguments.isEmpty {
        arguments.removeFirst()
      }
    }
    guard let directory, let subcommand = arguments.first ?? nil else { return [] }
    let rest = Array(arguments.dropFirst())
    let positional = rest.filter { $0.map { !$0.hasPrefix("-") } ?? true }
    func branch(_ name: String?, _ involvement: SessionResource.Involvement) -> [ResourceSighting] {
      guard let name, let normalized = normalizedBranch(name) else { return [] }
      return [.branch(name: normalized, directory: directory, involvement: involvement, at: at)]
    }

    switch subcommand {
    case "checkout", "switch":
      if let index = rest.firstIndex(where: { ["-b", "-B", "-c", "-C"].contains($0 ?? "") }),
        index + 1 < rest.count
      {
        return branch(rest[index + 1], .created)
      }
      // `git checkout -- file`, `git checkout main path/`: files, not a branch.
      guard !rest.contains("--"), positional.count == 1, let name = positional[0] else {
        return []
      }
      guard subcommand == "switch" || !looksLikePath(name, in: directory) else { return [] }
      return branch(name, .viewed)
    case "branch":
      let flags = rest.compactMap { $0 }.filter { $0.hasPrefix("-") }
      guard flags.isEmpty, let first = positional.first else { return [] }
      return branch(first, .created)
    case "push":
      if rest.contains(where: {
        ["-d", "--delete", "--tags", "--all", "--mirror"].contains($0 ?? "")
      }) {
        return []
      }
      // `git push`, `git push origin`: the branch checked out, when the transcript says which.
      guard positional.count >= 2 else { return branch(current, .changed) }
      return positional.dropFirst().flatMap { refspec -> [ResourceSighting] in
        guard var refspec else { return [] }
        if refspec.hasPrefix("+") { refspec.removeFirst() }
        let destination = refspec.split(separator: ":", omittingEmptySubsequences: false).last
          .map(String.init)
        if destination == "HEAD" || refspec == "HEAD" { return branch(current, .changed) }
        return branch(destination, .changed)
      }
    case "commit", "merge", "rebase", "cherry-pick", "revert", "pull":
      return branch(current, .changed)
    case "worktree":
      guard positional.first == "add" else { return [] }
      var found: [ResourceSighting] = []
      let options = Array(rest.drop { $0 != "add" }.dropFirst())
      var paths: [String?] = []
      var index = 0
      while index < options.count {
        let option = options[index]
        if let value = option, ["-b", "-B"].contains(value), index + 1 < options.count {
          found += branch(options[index + 1], .created)
          index += 2
          continue
        }
        if let value = option, value.hasPrefix("-") {
          // `--reason <text>` is the only one of its options to take a value.
          index += value == "--reason" ? 2 : 1
          continue
        }
        paths.append(option)
        index += 1
      }
      if let first = paths.first, let path = first, let resolved = resolve(path, from: directory) {
        found.insert(.worktree(path: resolved, involvement: .created, at: at), at: 0)
      }
      return found
    default:
      return []
    }
  }

  /// `origin/x` and `refs/heads/x` are `x`. `HEAD`, `-` and `@{-1}` name no branch.
  static func normalizedBranch(_ name: String) -> String? {
    var name = name
    for prefix in ["refs/heads/", "refs/remotes/origin/", "origin/", "upstream/"]
    where name.hasPrefix(prefix) {
      name.removeFirst(prefix.count)
    }
    guard !name.isEmpty, name != "HEAD", name != "-", !name.contains("@{"), !name.contains(" ")
    else { return nil }
    return name
  }

  private static func looksLikePath(_ name: String, in directory: String) -> Bool {
    name == "." || name.hasPrefix("./") || name.hasPrefix("../") || name.hasPrefix("/")
      || FileManager.default.fileExists(
        atPath: (directory as NSString).appendingPathComponent(name))
  }

  // MARK: - Folders

  /// The worktree a folder is inside, when it is one of the places agents make theirs.
  public static func worktree(containing directory: String) -> String? {
    for (marker, depth) in [
      ("/.claude/worktrees/", 1), ("/.codex/worktrees/", 2), ("/.worktrees/", 1),
    ] {
      guard let range = directory.range(of: marker) else { continue }
      let components = directory[range.upperBound...].split(separator: "/").prefix(depth)
      guard components.count == depth else { continue }
      return String(directory[..<range.upperBound]) + components.joined(separator: "/")
    }
    return nil
  }

  /// A path made absolute against the folder it was typed in. `~` is the user's home.
  static func resolve(_ path: String, from directory: String?) -> String? {
    if path.hasPrefix("/") { return (path as NSString).standardizingPath }
    if path == "~" || path.hasPrefix("~/") { return (path as NSString).expandingTildeInPath }
    guard let directory else { return nil }
    return ((directory as NSString).appendingPathComponent(path) as NSString).standardizingPath
  }
}

/// A simple command, its program found behind whatever runs it: `rtk git status`,
/// `env GH_REPO=x gh pr view`, `/usr/local/bin/gh`.
struct Invocation {
  let program: String
  let arguments: [String?]

  init?(_ words: [String?]) {
    var words = words[...]
    while let first = words.first {
      guard let word = first else { return nil }
      let name = (word as NSString).lastPathComponent
      if word.contains("="), !word.hasPrefix("-"), !word.hasPrefix("/") {
        words = words.dropFirst()
      } else if ["rtk", "env", "command", "sudo", "time", "nohup", "exec", "noglob"].contains(name)
      {
        words = words.dropFirst()
      } else {
        program = name
        arguments = Array(words.dropFirst())
        return
      }
    }
    return nil
  }

  struct ForgeVerb {
    let noun: String
    let action: String
    let index: Int
  }

  /// `gh pr view`, `glab mr note`: the noun and the action, wherever global options put them.
  var forgeVerb: ForgeVerb? {
    let nouns: Set<String> = program == "gh" ? ["issue", "pr"] : ["issue", "mr"]
    guard let nounIndex = arguments.firstIndex(where: { nouns.contains($0 ?? "") }),
      let noun = arguments[nounIndex], nounIndex + 1 < arguments.count,
      let action = arguments[nounIndex + 1]
    else { return nil }
    return ForgeVerb(noun: noun, action: action, index: nounIndex + 1)
  }

  /// Options of `gh` and `glab` that take a value, which is then not the number.
  private static let valueOptions: Set<String> = [
    "-R", "--repo", "-b", "--body", "-t", "--title", "-B", "--base", "-H", "--head", "--json",
    "-q", "--jq", "-F", "--body-file", "-l", "--label", "-a", "--assignee", "-m", "--milestone",
    "--template", "-r", "--reviewer", "-p", "--project", "-d", "--description", "-s", "--state",
    "--source-branch", "--target-branch", "-c", "--comments", "--message", "-T",
  ]

  /// The number the command is about: the first argument after the action that is a number, the
  /// values of options left aside.
  func forgeNumber(after verb: ForgeVerb) -> Int? {
    var index = verb.index + 1
    while index < arguments.count {
      guard let argument = arguments[index] else {
        index += 1
        continue
      }
      if Self.valueOptions.contains(argument) {
        index += 2
        continue
      }
      if argument.hasPrefix("-") {
        index += 1
        continue
      }
      var candidate = argument
      if candidate.hasPrefix("#") || candidate.hasPrefix("!") { candidate.removeFirst() }
      if let number = Int(candidate), number > 0 { return number }
      // A URL is read as a URL; a branch name says nothing without the network.
      return nil
    }
    return nil
  }

  /// The value of an option: `-R x`, `--repo x`, `--repo=x`.
  func option(_ names: String...) -> String? {
    for (index, argument) in arguments.enumerated() {
      guard let argument else { continue }
      for name in names {
        if argument == name, index + 1 < arguments.count { return arguments[index + 1] }
        if argument.hasPrefix(name + "=") { return String(argument.dropFirst(name.count + 1)) }
      }
    }
    return nil
  }
}
