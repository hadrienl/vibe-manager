import Foundation
import Observation
import VibeApplication
import VibeDomain

/// Adding a repository to a session that exists: the same road as creation, for one folder.
///
/// Read when designated, planned on every change, prepared only once the user confirms what the
/// plan shows.
@MainActor
@Observable
public final class RepositoryAttachmentModel {
  public let sessionID: SessionID
  public let sessionName: String
  public private(set) var repository: SessionDraftRepository?
  public private(set) var plan: RepositoryPlan?
  public private(set) var sessionFolderPath: String?
  public private(set) var isWorking = false
  public private(set) var failure: String?

  private var inspection: RepositoryInspection?
  private let attach: AttachRepository
  private let isRunning: @MainActor () -> Bool

  init(
    sessionID: SessionID,
    sessionName: String,
    attach: AttachRepository,
    isRunning: @escaping @MainActor () -> Bool
  ) {
    self.sessionID = sessionID
    self.sessionName = sessionName
    self.attach = attach
    self.isRunning = isRunning
  }

  /// A repository whose plan is held back is not attached: after creation there is nothing to
  /// gain from a line that cannot be prepared, and resolving the conflict is right there.
  public var canAttach: Bool {
    !isWorking && repository != nil && plan.map { !$0.isBlocked } == true
  }

  public func folderChosen(_ path: String) async {
    let repository = SessionDraftRepository(path: path)
    self.repository = repository
    plan = nil
    // Read once, when designated; changing the mode or the base replans from what was read.
    self.inspection = await attach.inspect(repository)
    await refresh()
  }

  public func setMode(_ mode: RepositoryAttachmentMode) async {
    repository?.mode = mode
    repository?.choice = nil
    await refresh()
  }

  public func setBase(_ base: RepositoryBase) async {
    repository?.base = base
    await refresh()
  }

  /// The session's slug is fixed, so renaming it is not one of the ways out offered here.
  static func isOffered(_ resolution: RepositoryResolution) -> Bool {
    if case .changeSlug = resolution { return false }
    if case .remove = resolution { return false }
    return true
  }

  @discardableResult
  func resolve(_ resolution: RepositoryResolution) async -> RepositoryResolutionEffect {
    guard var repository else { return .applied }
    let effect = repository.apply(resolution)
    if effect == .applied {
      self.repository = repository
      await refresh()
    }
    return effect
  }

  public func refresh() async {
    guard let repository else { return }
    do {
      let workspacePlan = try await attach.plan(
        sessionID: sessionID, adding: repository, inspection: inspection)
      guard repository == self.repository else { return }
      plan = workspacePlan.repositories.first
      sessionFolderPath = workspacePlan.sessionFolderPath
      failure = nil
    } catch {
      failure = (error as? LocalizedError)?.errorDescription ?? "This repository cannot be planned."
    }
  }

  /// Prepares the repository and attaches it. `nil` when it could not be attached at all.
  public func confirm() async -> RepositoryAttachment? {
    guard let repository, !isWorking else { return nil }
    isWorking = true
    defer { isWorking = false }
    do {
      return try await attach(sessionID: sessionID, adding: repository, isRunning: isRunning())
    } catch {
      failure = (error as? LocalizedError)?.errorDescription ?? "The repository was not attached."
      return nil
    }
  }
}
