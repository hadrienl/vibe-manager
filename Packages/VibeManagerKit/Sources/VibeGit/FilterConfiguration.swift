import Foundation

/// What a repository's own configuration could make `git status` run, found without running
/// anything, so that it can be switched off for that `status`.
///
/// A `.gitattributes` naming `filter=x` makes `git status` run `filter.x.clean` (or `.process`) on
/// every file whose stat data changed. Defined in the repository's own `.git/config`, that is a
/// command a folder brought from an archive runs in whoever merely looks at it. The user's global
/// and system filters are theirs — Git LFS installed with `git lfs install` — and are left alone,
/// and so is a local definition identical to theirs, which `git lfs install --local` writes. What
/// such a filter itself reads from the repository is switched off instead: the repository's aliases
/// (`git media clean` falls back on `alias.media` when `git-media` is missing) and its Git LFS
/// extensions, which `git-lfs` runs on every file it cleans. Hooks declared in the configuration
/// (`hook.<name>.command`), which `core.hooksPath` does not reach, are disabled too.
struct FilterConfiguration: Hashable, Sendable {
  struct Entry: Hashable, Sendable {
    let scope: String
    let key: String
    let value: String?
  }

  let entries: [Entry]

  /// What `git config` is asked. A driver's name may be empty: `filter=` in `.gitattributes` names
  /// the driver `[filter ""]`.
  static let arguments = [
    "config", "--includes", "--show-scope", "-z", "--get-regexp",
    #"^(filter\..*\.(clean|smudge|process|required)|alias\..*|lfs\.extension\..*\.(clean|smudge)|hook\..*\.(command|event|enabled))$"#,
  ]

  /// The scopes a repository writes itself: its `config`, its `config.worktree`, and whatever they
  /// include.
  static let repositoryScopes: Set<String> = ["local", "worktree"]
  static let commandKeys = ["clean", "smudge", "process"]

  /// Records are `scope NUL key LF value NUL`, or `scope NUL key NUL` for a key without value.
  static func parse(_ output: Data) -> FilterConfiguration {
    let fields = output.split(separator: 0, omittingEmptySubsequences: false)
      .map { String(decoding: $0, as: UTF8.self) }
    var entries: [Entry] = []
    var index = 0
    while index + 1 < fields.count {
      let scope = fields[index]
      let keyAndValue = fields[index + 1]
      index += 2
      if let newline = keyAndValue.firstIndex(of: "\n") {
        entries.append(
          Entry(
            scope: scope, key: String(keyAndValue[..<newline]),
            value: String(keyAndValue[keyAndValue.index(after: newline)...])))
      } else {
        entries.append(Entry(scope: scope, key: keyAndValue, value: nil))
      }
    }
    return FilterConfiguration(entries: entries)
  }

  private var repositoryEntries: [Entry] {
    entries.filter { Self.repositoryScopes.contains($0.scope) }
  }

  /// The drivers to switch off: those with a command in a repository scope that the user's own
  /// configuration does not give, word for word, under the same key.
  var driversToNeutralize: [String] {
    var trusted: [String: Set<String>] = [:]
    for entry in entries where !Self.repositoryScopes.contains(entry.scope) {
      trusted[entry.key, default: []].insert(entry.value ?? "")
    }
    var drivers: Set<String> = []
    for entry in repositoryEntries {
      guard let driver = Self.driver(of: entry.key) else { continue }
      if trusted[entry.key]?.contains(entry.value ?? "") == true { continue }
      drivers.insert(driver)
    }
    return drivers.sorted()
  }

  /// The configuration given to Git for one `status`, as `(key, value)` pairs: the repository's
  /// drivers get an empty command and are no longer required, its aliases and Git LFS extensions
  /// become empty, its configured hooks are disabled.
  var neutralizations: [(key: String, value: String)] {
    var pairs: [(key: String, value: String)] = []
    for driver in driversToNeutralize {
      for variable in Self.commandKeys { pairs.append(("filter.\(driver).\(variable)", "")) }
      pairs.append(("filter.\(driver).required", "false"))
    }
    var emptied: Set<String> = []
    var hooks: Set<String> = []
    for entry in repositoryEntries {
      if entry.key.hasPrefix("alias.") || entry.key.hasPrefix("lfs.extension.") {
        emptied.insert(entry.key)
      } else if let hook = Self.hook(of: entry.key) {
        hooks.insert(hook)
      }
    }
    for key in emptied.sorted() { pairs.append((key, "")) }
    for hook in hooks.sorted() { pairs.append(("hook.\(hook).enabled", "false")) }
    return pairs
  }

  /// `filter.<driver>.clean` → `<driver>`, which may be empty or hold dots or an `=`.
  static func driver(of key: String) -> String? {
    name(in: key, section: "filter.", variables: commandKeys)
  }

  /// `hook.<name>.command` → `<name>`.
  static func hook(of key: String) -> String? {
    name(in: key, section: "hook.", variables: ["command", "event", "enabled"])
  }

  private static func name(in key: String, section: String, variables: [String]) -> String? {
    guard key.hasPrefix(section), let lastDot = key.lastIndex(of: ".") else { return nil }
    let start = key.index(key.startIndex, offsetBy: section.count)
    // `filter.clean`, with no subsection, has its last dot before the name would start.
    guard lastDot >= start else { return nil }
    guard variables.contains(String(key[key.index(after: lastDot)...])) else { return nil }
    return String(key[start..<lastDot])
  }

  /// `pairs` as Git reads them from the environment: `-c` cuts a key at its first `=`, and a
  /// driver may be named `a=b`; the Git a submodule is read with inherits the environment too.
  static func environment(for pairs: [(key: String, value: String)]) -> [String: String] {
    guard !pairs.isEmpty else { return [:] }
    var environment: [String: String] = ["GIT_CONFIG_COUNT": String(pairs.count)]
    for (index, pair) in pairs.enumerated() {
      environment["GIT_CONFIG_KEY_\(index)"] = pair.key
      environment["GIT_CONFIG_VALUE_\(index)"] = pair.value
    }
    return environment
  }
}
