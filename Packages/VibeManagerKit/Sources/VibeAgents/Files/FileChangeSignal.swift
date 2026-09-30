import Foundation

/// How files followed on `vnode` events are looked at again when no event came.
public enum FileWatching {
  /// The safety net under a file already watched: events carry every change on a local disk, so
  /// this only catches the rare one lost. Shared by every follower of a watched file.
  public static let safetyNet: Duration = .seconds(30)
}
