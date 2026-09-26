import Foundation
import VibeApplication
import VibeDomain

/// The folders sessions were created in, which the New Session sheet offers again (#39).
extension AppModel {
  /// Reads the history, or seeds it from the sessions when none was ever written: an existing
  /// installation gets its folders offered from the first sheet, not after three new sessions.
  func loadRecentFolders() async {
    if let stored = await recentFolderStore.load() {
      recentFolders = stored
      return
    }
    // A store that could not be read is not an installation without sessions: seeding from it
    // would write an empty history, and no later launch would seed again.
    guard case .loaded = state else { return }
    recentFolders = RecentFolders.seeded(from: sessions)
    await recentFolderStore.save(recentFolders)
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
    await recentFolderStore.save(recentFolders)
    diagnostics.record(
      .session, .info, "recentFolders.recorded", ["count": .count(recentFolders.entries.count)])
  }

  /// Remove from Recents, from a card of the sheet.
  func forgetRecentFolder(_ folder: RecentFolder) {
    recentFolders = recentFolders.removing(key: folder.key)
    let folders = recentFolders
    Task { await recentFolderStore.save(folders) }
  }
}
