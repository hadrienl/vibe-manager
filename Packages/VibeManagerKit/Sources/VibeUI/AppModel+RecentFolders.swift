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
