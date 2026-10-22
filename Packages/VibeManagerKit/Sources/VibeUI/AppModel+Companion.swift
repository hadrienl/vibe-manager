import Foundation
import VibeApplication
import VibeDomain
import os

private let companionLogger = Logger(
  subsystem: "eu.hadrien.VibeManager.companion", category: "remote")

/// What the mobile companion asks of the model beyond what the window reads (#400): the choices
/// of a new session, and its creation.
extension AppModel {
  /// The folders a new session is offered, the most recent first, as the New Session sheet lists
  /// them.
  public var companionRecentFolders: [String] {
    offeredRecentFolders.map(\.path)
  }

  /// A project icon's PNG, as the sessions wear it.
  public func companionIconPNG(_ sha256: String) async -> Data? {
    guard let id = SessionIconID(sha256: sha256) else { return nil }
    return await iconStore.pngData(for: id)
  }

  /// The project icon a folder offers, as the New Session sheet finds it.
  public func companionProjectIcon(inFolder path: String) async -> Data? {
    await projectIcons.icon(inFolder: (path as NSString).expandingTildeInPath)?.pngData
  }

  /// Stops what the session's agent does, as Escape in its terminal.
  public func companionInterrupt(_ id: SessionID) async {
    guard let session = sessions.first(where: { $0.id == id }) else { return }
    let model = conversations.show(session)
    companionLogger.notice(
      "interrupt: pane \(self.pane(for: id) != nil, privacy: .public), status \(String(describing: self.pane(for: id)?.status), privacy: .public), write \(model.write != nil, privacy: .public), key \(model.promptFormat.interruptKey, privacy: .public)"
    )
    await model.interrupt()
  }

  /// The prompt templates, in the user's order.
  public var companionTemplates: [PromptTemplate] {
    templates.library.templates
  }

  /// An agent's models, `[]` for one that offers no choice.
  public func companionModels(of providerID: String) async -> [AgentModel] {
    guard let provider = await agents?.provider(id: AgentProviderID(providerID)) else { return [] }
    return await provider.models()
  }

  /// Creates a session as the New Session sheet does, and starts its agent unless it is to wait
  /// in À faire. A name left empty is taken from the first line of the message, else the folder.
  public func createCompanionSession(
    name: String, folder: String, providerID: String, modelID: String?, prompt: String,
    start: Bool, coordinates: Bool, appearance: SessionAppearance? = nil
  ) async throws -> SessionID {
    guard let agents else { throw CompanionCreationError.noAgent }
    let path = (folder as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw CompanionCreationError.folderMissing }
    let given = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let firstLine =
      prompt.split(whereSeparator: \.isNewline).first.map(String.init)?
      .trimmingCharacters(in: .whitespaces) ?? ""
    let draft = SessionDraft(
      name: given.isEmpty
        ? String((firstLine.isEmpty ? (path as NSString).lastPathComponent : firstLine).prefix(60))
        : given,
      initialPrompt: prompt, providerID: providerID, modelID: modelID, appearance: appearance,
      workingDirectoryPath: path, palette: appearancePalette.offered,
      coordination: coordinates ? .coordinator : nil)
    let create = CreateSession(
      repository: repository, agents: agents, ticketContext: readTicketContext,
      icons: iconStore, diagnostics: diagnostics)
    var withIcon = draft
    // As the sheet does: a session given no icon wears its project's.
    if appearance == nil {
      withIcon.projectIcon = await projectIcons.icon(inFolder: path)
    }
    let creation: SessionCreation
    do {
      creation = try await create(withIcon)
    } catch let rejected as SessionCreationRejected {
      throw CompanionCreationError.rejected(
        rejected.issues.map { $0.errorDescription ?? "\($0)" }.joined(separator: " "))
    }
    await publish(creation, launching: start, tracked: false, follows: false)
    return creation.session.id
  }
}

/// Why the companion's session was not created: the phone says the first two in its language;
/// the Mac's sheet already words a rejected draft, in the Mac's.
public enum CompanionCreationError: Error {
  case noAgent
  case folderMissing
  case rejected(String)
}
