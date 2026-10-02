import Foundation
import VibeDomain

/// What a session is shown as: its name and its badge (#183), and the theme of its conversation
/// (#274).
public struct SessionIdentity: Hashable, Sendable {
  public var name: String
  public var appearance: SessionAppearance
  public var conversationTheme: String?

  public init(name: String, appearance: SessionAppearance, conversationTheme: String? = nil) {
    self.name = name
    self.appearance = appearance
    self.conversationTheme = conversationTheme
  }

  public init(of session: WorkSession) {
    self.init(
      name: session.name, appearance: session.appearance,
      conversationTheme: session.conversationTheme)
  }
}

/// One rename, one change of badge or of theme, as ⌘Z undoes it.
public struct SessionIdentityChange: Hashable, Sendable {
  public let id: SessionID
  public let before: SessionIdentity
  public let after: SessionIdentity

  public init(id: SessionID, before: SessionIdentity, after: SessionIdentity) {
    self.id = id
    self.before = before
    self.after = after
  }

  public var reversed: SessionIdentityChange {
    SessionIdentityChange(id: id, before: after, after: before)
  }
}

public enum SessionIdentityError: Error, Equatable, Sendable {
  /// The session is no longer stored.
  case sessionNotFound
  /// The badge cannot be stored: a symbol or a colour that is not one.
  case invalidAppearance
  /// The project's icon could not be copied into the data folder, and nothing was changed.
  case iconNotKept
  /// A theme named by nothing: `nil` is how a session follows the settings.
  case invalidConversationTheme
}

/// Renames a session, or changes its badge, after it was created (#183).
///
/// The identity is only what the session is shown as: nothing else is written — not the branch,
/// the worktree, the agent and its conversation, the lifecycle, the last activity nor the order —
/// and no process hears of it. A running agent goes on as if nothing happened.
public struct EditSessionIdentity: Sendable {
  private let repository: any SessionRepository
  private let icons: (any SessionIconStore)?
  private let projectIcons: any ProjectIconFinding
  private let diagnostics: Diagnostics

  public init(
    repository: any SessionRepository,
    icons: (any SessionIconStore)? = nil,
    projectIcons: any ProjectIconFinding = NoProjectIcons(),
    diagnostics: Diagnostics = .disabled
  ) {
    self.repository = repository
    self.icons = icons
    self.projectIcons = projectIcons
    self.diagnostics = diagnostics
  }

  /// Gives the session this name, under the rules of a creation. `nil` when it already had it:
  /// nothing is written, and there is nothing to undo.
  ///
  /// - Throws: the `SessionDraftIssue` that refuses the name, and the store left as it was; or
  ///   `SessionIdentityError.sessionNotFound`.
  @discardableResult
  public func rename(_ id: SessionID, to raw: String) async throws -> SessionIdentityChange? {
    let name = try SessionName.validated(raw).get()
    return try await write(id) { $0.name = name }
  }

  /// Gives the session this badge. `icon` is the project icon it names, copied into the data
  /// folder before the session is written, so that a stored session never names an icon that is
  /// not there. `nil` when the badge was already this one.
  @discardableResult
  public func setAppearance(
    _ appearance: SessionAppearance, keeping icon: ProjectIcon? = nil, for id: SessionID
  ) async throws -> SessionIdentityChange? {
    guard Self.isStorable(appearance) else { throw SessionIdentityError.invalidAppearance }
    if let icon, icon.id == appearance.iconID {
      guard let icons else { throw SessionIdentityError.iconNotKept }
      do {
        try await icons.save(icon)
      } catch {
        diagnostics.record(.session, .error, "session.iconNotKept")
        throw SessionIdentityError.iconNotKept
      }
    }
    return try await write(id) { $0.appearance = appearance }
  }

  /// Gives the session's conversation this theme (#274), or the settings' with `nil`. `nil` when
  /// it already had it. A theme that is not there is written all the same: it is drawn as the
  /// settings' until it is back.
  @discardableResult
  public func setConversationTheme(_ theme: String?, for id: SessionID) async throws
    -> SessionIdentityChange?
  {
    guard theme.map({ !$0.isEmpty }) ?? true else {
      throw SessionIdentityError.invalidConversationTheme
    }
    return try await write(id) { $0.conversationTheme = theme }
  }

  /// Puts back a name and a badge as they were, for ⌘Z — only if the session still has the ones
  /// the change gave it. Anything else means it was changed since, and the change is not undone
  /// over that: `nil`.
  @discardableResult
  public func apply(_ change: SessionIdentityChange) async throws -> SessionIdentityChange? {
    do {
      let updated = try await repository.mutate(id: change.id) { session in
        guard SessionIdentity(of: session) == change.before else { throw ChangedSince() }
        session.name = change.after.name
        session.appearance = change.after.appearance
        session.conversationTheme = change.after.conversationTheme
      }
      guard updated != nil else { throw SessionIdentityError.sessionNotFound }
      return change
    } catch is ChangedSince {
      return nil
    }
  }

  /// Thrown out of the transform, so that nothing is written.
  private struct ChangedSince: Error {}

  /// What the session would be given if it were created now with its name and its folder: the
  /// project's icon when the folder has one, and the icon found, which `setAppearance` then keeps.
  /// Its symbol and colour are picked among `palette`, the lists the Settings offer now (#199).
  public func defaultAppearance(
    for session: WorkSession, palette: SessionAppearancePalette = .default
  ) async -> (
    appearance: SessionAppearance, icon: ProjectIcon?
  ) {
    let icon: ProjectIcon? =
      if let path = session.repositories.first?.path {
        await projectIcons.icon(inFolder: path)
      } else {
        nil
      }
    return (
      palette.defaultAppearance(forName: session.name, projectIcon: icon?.id),
      icon
    )
  }

  /// The icon of the session's folder, offered in the picker while it has none.
  public func projectIcon(for session: WorkSession) async -> ProjectIcon? {
    guard let path = session.repositories.first?.path else { return nil }
    return await projectIcons.icon(inFolder: path)
  }

  /// Writes the change in one step, and says what it changed. The identity is only ever changed
  /// from the main actor, one change at a time: what is read before is what the change replaces.
  private func write(_ id: SessionID, _ change: @escaping @Sendable (inout WorkSession) -> Void)
    async throws -> SessionIdentityChange?
  {
    guard let stored = try await repository.session(id: id) else {
      throw SessionIdentityError.sessionNotFound
    }
    var changed = stored
    change(&changed)
    let before = SessionIdentity(of: stored)
    let after = SessionIdentity(of: changed)
    guard before != after else { return nil }
    guard try await repository.mutate(id: id, change) != nil else {
      throw SessionIdentityError.sessionNotFound
    }
    return SessionIdentityChange(id: id, before: before, after: after)
  }

  private static func isStorable(_ appearance: SessionAppearance) -> Bool {
    guard !appearance.symbolName.isEmpty else { return false }
    let color = appearance.colorHex
    guard color.count == 7 || color.count == 9, color.first == "#" else { return false }
    return color.dropFirst().allSatisfy(\.isHexDigit)
  }
}
