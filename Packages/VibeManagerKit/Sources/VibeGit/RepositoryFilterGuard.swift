import Foundation

/// The filter drivers a repository defines for itself, found without running anything, so that a
/// `git status` can be told to ignore them.
///
/// A `.gitattributes` naming `filter=x` makes `git status` run `filter.x.clean` (or `.process`)
/// on every file whose stat data changed. Defined in the repository's own `.git/config`, that is a
/// command a folder brought from an archive runs in whoever merely looks at it. The user's global
/// and system configuration is theirs — Git LFS installed with `git lfs install` — and is left
/// alone; so is a local definition identical to it, which is what `git lfs install --local` writes.
struct FilterConfiguration: Hashable, Sendable {
  struct Entry: Hashable, Sendable {
    let scope: String
    let origin: String
    let key: String
    let value: String?
  }

  let entries: [Entry]

  /// What `git config` is asked: every filter command, what the configuration includes, and two
  /// keys that are always in a repository's own file or say where else its configuration lives.
  static let arguments = [
    "config", "--includes", "--show-scope", "--show-origin", "-z", "--get-regexp",
    #"^(filter\..+\.(clean|smudge|process|required)|include\.path|includeif\..+\.path|core\.repositoryformatversion|extensions\.worktreeconfig)$"#,
  ]

  /// The scopes a repository writes itself: its `config`, its `config.worktree`, and whatever they
  /// include.
  static let repositoryScopes: Set<String> = ["local", "worktree"]
  static let commandKeys = ["clean", "smudge", "process"]

  /// Records are `scope NUL origin NUL key LF value NUL`, or `… key NUL` for a key without value.
  static func parse(_ output: Data) -> FilterConfiguration {
    let fields = output.split(separator: 0, omittingEmptySubsequences: false)
      .map { String(decoding: $0, as: UTF8.self) }
    var entries: [Entry] = []
    var index = 0
    while index + 2 < fields.count {
      let scope = fields[index]
      let origin = fields[index + 1]
      let keyAndValue = fields[index + 2]
      index += 3
      if let newline = keyAndValue.firstIndex(of: "\n") {
        entries.append(
          Entry(
            scope: scope, origin: origin, key: String(keyAndValue[..<newline]),
            value: String(keyAndValue[keyAndValue.index(after: newline)...])))
      } else {
        entries.append(Entry(scope: scope, origin: origin, key: keyAndValue, value: nil))
      }
    }
    return FilterConfiguration(entries: entries)
  }

  /// The drivers to switch off: those with a command in a repository scope that the user's own
  /// configuration does not give, word for word, under the same key.
  var driversToNeutralize: [String] {
    var trusted: [String: Set<String>] = [:]
    for entry in entries where !Self.repositoryScopes.contains(entry.scope) {
      trusted[entry.key, default: []].insert(entry.value ?? "")
    }
    var drivers: Set<String> = []
    for entry in entries where Self.repositoryScopes.contains(entry.scope) {
      guard let driver = Self.driver(of: entry.key) else { continue }
      if trusted[entry.key]?.contains(entry.value ?? "") == true { continue }
      drivers.insert(driver)
    }
    return drivers.sorted()
  }

  /// `filter.<driver>.clean` → `<driver>`, which may itself hold dots or an `=`.
  static func driver(of key: String) -> String? {
    guard key.hasPrefix("filter."), let lastDot = key.lastIndex(of: ".") else { return nil }
    let name = key[key.index(key.startIndex, offsetBy: 7)..<lastDot]
    let variable = key[key.index(after: lastDot)...]
    guard !name.isEmpty, commandKeys.contains(String(variable)) else { return nil }
    return String(name)
  }

  /// The configuration given to Git so that none of `drivers` runs: an empty command is no
  /// command, and a driver that is not required lets the file through unfiltered. Given through
  /// `GIT_CONFIG_*`, which takes any name — `-c` cuts a key at its first `=` — and which the Git
  /// a submodule is read with inherits.
  static func environment(neutralizing drivers: [String]) -> [String: String] {
    guard !drivers.isEmpty else { return [:] }
    var environment: [String: String] = [:]
    var count = 0
    for driver in drivers {
      for (variable, value) in [
        ("clean", ""), ("smudge", ""), ("process", ""), ("required", "false"),
      ] {
        environment["GIT_CONFIG_KEY_\(count)"] = "filter.\(driver).\(variable)"
        environment["GIT_CONFIG_VALUE_\(count)"] = value
        count += 1
      }
    }
    environment["GIT_CONFIG_COUNT"] = String(count)
    return environment
  }

  /// Whether the answer depends on more than the files it came from: a conditional include on the
  /// branch checked out, or a per-worktree configuration beside the shared one.
  var dependsOnMoreThanItsFiles: Bool {
    entries.contains { entry in
      (entry.key.hasPrefix("includeif.onbranch:"))
        || (entry.key == "extensions.worktreeconfig" && entry.value?.lowercased() != "false")
    }
  }

  /// The files that decide the answer, resolved against `directory`: those the repository's
  /// entries came from, and every file its includes name — missing ones too, since creating one
  /// changes the answer.
  func files(in directory: String) -> [String] {
    var files: Set<String> = []
    for entry in entries where Self.repositoryScopes.contains(entry.scope) {
      guard let origin = Self.path(ofOrigin: entry.origin, in: directory) else { continue }
      files.insert(origin)
      let isInclude =
        entry.key == "include.path"
        || (entry.key.hasPrefix("includeif.") && entry.key.hasSuffix(".path"))
      if isInclude, let value = entry.value, !value.isEmpty {
        files.insert(Self.resolve(value, besides: origin))
      }
    }
    return files.sorted()
  }

  static func path(ofOrigin origin: String, in directory: String) -> String? {
    guard origin.hasPrefix("file:") else { return nil }
    let path = String(origin.dropFirst(5))
    return path.hasPrefix("/")
      ? (path as NSString).standardizingPath
      : ((directory as NSString).appendingPathComponent(path) as NSString).standardizingPath
  }

  /// An include path as Git reads it: `~/` is the home folder, a relative path is relative to the
  /// file that names it.
  static func resolve(_ value: String, besides origin: String) -> String {
    if value.hasPrefix("~/") {
      return (NSHomeDirectory() as NSString).appendingPathComponent(String(value.dropFirst(2)))
    }
    if value.hasPrefix("/") { return (value as NSString).standardizingPath }
    let folder = (origin as NSString).deletingLastPathComponent
    return ((folder as NSString).appendingPathComponent(value) as NSString).standardizingPath
  }
}

/// What a repository's configuration files look like on disk, to know without Git whether they
/// changed: identity, size and date of each, or their absence.
struct ConfigurationFingerprint: Hashable, Sendable {
  struct File: Hashable, Sendable {
    let path: String
    let inode: UInt64?
    let size: UInt64?
    let modified: Date?
  }

  let files: [File]

  static func of(_ paths: [String]) -> ConfigurationFingerprint {
    ConfigurationFingerprint(
      files: paths.map { path in
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return File(
          path: path,
          inode: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
          size: (attributes?[.size] as? NSNumber)?.uint64Value,
          modified: attributes?[.modificationDate] as? Date)
      })
  }
}

/// The drivers to switch off in each folder, remembered while its configuration files do not move.
///
/// Remembering is not what keeps a repository out: changing its configuration afterwards already
/// takes a program running as the user. It spares a `git config` before every `git status`.
public actor RepositoryFilterGuard {
  public static let shared = RepositoryFilterGuard()

  private struct Known {
    let drivers: [String]
    let fingerprint: ConfigurationFingerprint
  }

  private var known: [String: Known] = [:]
  private(set) var enumerations = 0

  public init() {}

  /// The drivers to switch off in `directory`, or `nil` when Git could not say — and then nothing
  /// may read the working tree.
  func drivers(
    in directory: String,
    enumerate: @Sendable () async -> Data?
  ) async -> [String]? {
    if let cached = known[directory],
      ConfigurationFingerprint.of(cached.fingerprint.files.map(\.path)) == cached.fingerprint
    {
      return cached.drivers
    }
    enumerations += 1
    guard let output = await enumerate() else {
      known[directory] = nil
      return nil
    }
    let configuration = FilterConfiguration.parse(output)
    let drivers = configuration.driversToNeutralize
    let files = configuration.files(in: directory)
    if configuration.dependsOnMoreThanItsFiles || files.isEmpty {
      known[directory] = nil
    } else {
      known[directory] = Known(drivers: drivers, fingerprint: .of(files))
    }
    return drivers
  }
}
