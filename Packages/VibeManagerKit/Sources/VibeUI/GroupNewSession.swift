import VibeApplication

/// Whether a session can be started in a group's folder from its header: the + shown on hover, the
/// menu entry and the VoiceOver action all read this one value, so they never disagree (#106).
public enum GroupNewSession: Equatable, Sendable {
  /// No folder to start in, or the header is being renamed: no button, no entry.
  case hidden
  /// Shown, but a click does nothing; the reason is in the help tag.
  case disabled(Reason)
  case enabled(folder: String)

  public enum Reason: Equatable, Sendable {
    case folderMissing
    case creationUnavailable
  }

  public static func availability(
    for group: SessionGroup, canCreateSession: Bool, isRenaming: Bool = false
  ) -> GroupNewSession {
    guard let folder = group.id, !isRenaming else { return .hidden }
    if group.isMissing { return .disabled(.folderMissing) }
    guard canCreateSession else { return .disabled(.creationUnavailable) }
    return .enabled(folder: folder.path)
  }

  public var isShown: Bool { self != .hidden }

  public var isEnabled: Bool {
    if case .enabled = self { return true }
    return false
  }
}
