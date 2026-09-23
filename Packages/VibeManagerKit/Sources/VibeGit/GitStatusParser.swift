import Foundation
import VibeDomain

/// What `git status --porcelain=v2 -z --branch` said, before it is dated and placed.
struct ParsedStatus: Hashable, Sendable {
  var branch = BranchStatus()
  var entries: [WorkingTreeEntry] = []
  var counts = WorkingTreeCounts()
  var isTruncated = false
}

/// Reads `git status --porcelain=v2 -z --branch`.
///
/// Records are separated by NUL, so a path may hold spaces, quotes, tabs or new lines and is still
/// read exactly as Git wrote it. Every record is counted; only the first `limit` are kept, so a
/// repository with eighty thousand changes costs its counts and not its list.
struct GitStatusParser: Sendable {
  func parse(_ output: Data, limit: Int) -> ParsedStatus {
    var parsed = ParsedStatus()
    var oid: String?
    var head: String?
    var upstream: String?
    var ahead: Int?
    var behind: Int?

    let records = output.split(separator: 0, omittingEmptySubsequences: true)
    var index = records.startIndex
    while index < records.endIndex {
      let record = String(decoding: records[index], as: UTF8.self)
      index += 1
      guard let type = record.first else { continue }

      switch type {
      case "#":
        let fields = record.split(separator: " ", maxSplits: 2).map(String.init)
        guard fields.count == 3 else { continue }
        switch fields[1] {
        case "branch.oid": oid = fields[2] == "(initial)" ? nil : fields[2]
        case "branch.head": head = fields[2] == "(detached)" ? nil : fields[2]
        case "branch.upstream": upstream = fields[2]
        case "branch.ab":
          let counts = fields[2].split(separator: " ")
          if counts.count == 2 {
            ahead = Int(counts[0].dropFirst())
            behind = Int(counts[1].dropFirst())
          }
        default: break
        }
      case "1":
        // 1 XY sub mH mI mW hH hI path
        let fields = record.split(separator: " ", maxSplits: 8).map(String.init)
        guard fields.count == 9 else { continue }
        add(
          entry(path: fields[8], codes: fields[1], submodule: fields[2], origin: nil),
          to: &parsed, limit: limit)
      case "2":
        // 2 XY sub mH mI mW hH hI Xscore path, then the original path as a record of its own.
        let fields = record.split(separator: " ", maxSplits: 9).map(String.init)
        let origin =
          index < records.endIndex
          ? String(decoding: records[index], as: UTF8.self) : nil
        index += 1
        guard fields.count == 10 else { continue }
        let similarity = Int(fields[8].dropFirst()) ?? 0
        add(
          entry(
            path: fields[9], codes: fields[1], submodule: fields[2],
            origin: origin.map { ($0, similarity) }),
          to: &parsed, limit: limit)
      case "u":
        // u XY sub m1 m2 m3 mW h1 h2 h3 path
        let fields = record.split(separator: " ", maxSplits: 10).map(String.init)
        guard fields.count == 11 else { continue }
        add(
          WorkingTreeEntry(path: fields[10], kind: .conflicted(Self.conflict(fields[1]))),
          to: &parsed, limit: limit)
      case "?":
        let path = String(record.dropFirst(2))
        add(
          WorkingTreeEntry(
            path: path, kind: path.hasSuffix("/") ? .untrackedDirectory : .untracked),
          to: &parsed, limit: limit)
      default:
        // `!` is an ignored file, and never asked for.
        continue
      }
    }

    parsed.branch = BranchStatus(
      headRevision: oid, branchName: head, upstream: upstream, ahead: ahead, behind: behind)
    return parsed
  }

  private func add(_ entry: WorkingTreeEntry, to parsed: inout ParsedStatus, limit: Int) {
    switch entry.kind {
    case .conflicted:
      parsed.counts.conflicted += 1
    case .untracked, .untrackedDirectory:
      parsed.counts.untracked += 1
    case .tracked, .submodule:
      if entry.isStaged { parsed.counts.staged += 1 }
      if entry.isUnstaged { parsed.counts.unstaged += 1 }
    }
    if parsed.entries.count < limit {
      parsed.entries.append(entry)
    } else {
      parsed.isTruncated = true
    }
  }

  private func entry(
    path: String, codes: String, submodule: String, origin: (String, Int)?
  ) -> WorkingTreeEntry {
    let characters = Array(codes)
    let staged = characters.count == 2 ? Self.change(characters[0], origin: origin) : nil
    let unstaged = characters.count == 2 ? Self.change(characters[1], origin: origin) : nil
    guard submodule.hasPrefix("S"), submodule.count == 4 else {
      return WorkingTreeEntry(path: path, kind: .tracked(staged: staged, unstaged: unstaged))
    }
    let flags = Array(submodule)
    var change: SubmoduleChange = []
    if flags[1] == "C" { change.insert(.commitChanged) }
    if flags[2] == "M" { change.insert(.trackedChanges) }
    if flags[3] == "U" { change.insert(.untrackedChanges) }
    return WorkingTreeEntry(
      path: path, kind: .submodule(staged: staged, unstaged: unstaged, change))
  }

  private static func change(_ code: Character, origin: (String, Int)?) -> FileChange? {
    switch code {
    case "M": return .modified
    case "T": return .typeChanged
    case "A": return .added
    case "D": return .deleted
    case "R": return origin.map { .renamed(from: $0.0, similarity: $0.1) } ?? .modified
    case "C": return origin.map { .copied(from: $0.0, similarity: $0.1) } ?? .added
    default: return nil
    }
  }

  private static func conflict(_ codes: String) -> ConflictKind {
    switch codes {
    case "DD": return .bothDeleted
    case "AU": return .addedByUs
    case "UD": return .deletedByThem
    case "UA": return .addedByThem
    case "DU": return .deletedByUs
    case "AA": return .bothAdded
    default: return .bothModified
    }
  }
}
