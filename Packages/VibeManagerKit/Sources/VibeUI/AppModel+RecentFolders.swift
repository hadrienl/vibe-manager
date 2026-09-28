import Foundation
import VibeApplication
import VibeDomain

/// The folders sessions were created in, which the New Session sheet offers again (#39).
extension AppModel {
  /// Reads the history, or seeds it from the sessions when none was ever written: an existing
  /// installation gets its folders offered from the first sheet, not after three new sessions.
  ///
  /// A store of sessions that could not be read is not an installation without sessions: seeding
  /// from it would write an empty history, and no later launch would seed again. The history then
  /// waits for the first list read in full, and nothing is written until it has one.
  func loadRecentFolders() async {
    guard recentFolderHistory != .ready else { return }
    let stored = await recentFolderStore.load()
    guard recentFolderHistory != .ready else { return }
    let base: RecentFolders
    if let stored {
      base = stored
    } else if case .loaded(let sessions) = state {
      base = RecentFolders.seeded(from: sessions)
    } else {
      recentFolderHistory = .awaitingSessions
      return
    }
    // Folders recorded while the history waited stay on top of it, and replace the entries that
    // were only their spelling.
    let recorded = recentFolders.entries
    let spellings = Set(recorded.map { RecentFolder.lexicalKey(of: $0.path) })
    recentFolders = RecentFolders(recorded + base.entries.filter { !spellings.contains($0.key) })
    recentFolderHistory = .ready
    if stored == nil || !recorded.isEmpty {
      await recentFolderStore.save(recentFolders)
    }
  }

  /// The folder of a session just stored, offered at once: a New Session sheet opened while the
  /// agent starts — which takes seconds — proposes it already. Kept beside the history, never in
  /// it: only `rememberFolder(of:)` changes the history, once the agent runs, and it then drops
  /// this note. Written into the history by its spelling, the folder would be listed twice next
  /// to an equivalent spelling already there, and a full history would lose its oldest folder.
  ///
  /// Its identity is resolved meanwhile, off the main actor, without holding up the launch.
  func noteFolder(of session: WorkSession) {
    guard let path = session.repositories.first?.path, !path.isEmpty else { return }
    let noted = RecentFolder(lexicalPath: path)
    notedFolder = noted
    Task { [weak self] in
      let key = await Task.detached { CanonicalPath.of(noted.key) }.value
      guard let self, self.notedFolder == noted else { return }
      self.notedFolder = RecentFolder(path: path, key: key)
    }
  }

  /// What the New Session sheet offers: the history, with the folder noted meanwhile at the top —
  /// its own entry moved up when the history already has it, under whatever spelling.
  var offeredRecentFolders: [RecentFolder] {
    let entries = recentFolders.entries
    guard let noted = notedFolder else { return entries }
    let spelling = RecentFolder.lexicalKey(of: noted.path)
    let isNoted = { (entry: RecentFolder) in
      entry.key == noted.key || RecentFolder.lexicalKey(of: entry.path) == spelling
    }
    let top = entries.first(where: isNoted) ?? noted
    return Array(([top] + entries.filter { !isNoted($0) }).prefix(RecentFolders.limit))
  }

  /// Puts the session's folder at the top of the history, whatever gave it: the open panel, a
  /// card, a typed path or a template. The folder is the one the session was created in.
  ///
  /// Its identity is resolved through its links here, and only here: creation has just opened
  /// this folder, so reading it again raises no consent alert that has not already been answered.
  func rememberFolder(of session: WorkSession) async {
    guard let path = session.repositories.first?.path, !path.isEmpty else { return }
    let lexical = RecentFolder.lexicalKey(of: path)
    let key = await Task.detached { CanonicalPath.of(lexical) }.value
    // A folder seeded from the sessions was keyed by its spelling: that entry is this folder too.
    recentFolders = recentFolders.removing(key: lexical).recording(
      RecentFolder(path: path, key: key))
    // In the history now: the note that stood for it goes, in the same step.
    if let noted = notedFolder, RecentFolder.lexicalKey(of: noted.path) == lexical {
      notedFolder = nil
    }
    // A history of this one folder, once written, would never be seeded again: until the history
    // is read or seeded, the folder is only kept in memory, and joins it then.
    guard recentFolderHistory == .ready else { return }
    await recentFolderStore.save(recentFolders)
    diagnostics.record(
      .session, .info, "recentFolders.recorded", ["count": .count(recentFolders.entries.count)])
  }

  /// Remove from Recents, from a card of the sheet.
  func forgetRecentFolder(_ folder: RecentFolder) {
    recentFolders = recentFolders.removing(key: folder.key)
    guard recentFolderHistory == .ready else { return }
    let folders = recentFolders
    Task { await recentFolderStore.save(folders) }
  }
}

/// Where the recent folders stand: whether what `AppModel.recentFolders` holds may be written.
enum RecentFolderHistory: Equatable {
  /// The launch has not read it yet.
  case unread
  /// Never written, and the sessions to seed it from could not be read.
  case awaitingSessions
  /// Read from the store, or seeded from sessions read in full.
  case ready
}
