import Foundation

/// Everything the user fills in before a session exists.
///
/// A draft is never half a `WorkSession`: nothing is written until `CreateSession` turns a whole
/// draft into one. That is what lets Cancel leave no trace, with nothing to clean up afterwards.
public struct SessionDraft: Hashable, Sendable {
  public var name: String
  public var initialPrompt: String
  public var providerID: String?
  /// `nil` means "let the agent decide", which is a real answer: both CLIs read a default from
  /// their own configuration, and neither guarantees a model catalogue exists to choose from.
  public var modelID: String?
  /// `nil` means "not chosen yet", so the identity keeps following the name.
  public var appearance: SessionAppearance?
  public var workingDirectoryPath: String?
  /// The template being filled in, if any. While there is one, the prompt is its rendering and
  /// `initialPrompt` is not read.
  public var templateFill: PromptTemplateFill?
  /// What was typed in the Ticket field (#69): an address, or `#12`. Empty for none.
  public var ticketText: String

  public init(
    name: String = "",
    initialPrompt: String = "",
    providerID: String? = nil,
    modelID: String? = nil,
    appearance: SessionAppearance? = nil,
    workingDirectoryPath: String? = nil,
    templateFill: PromptTemplateFill? = nil,
    ticketText: String = ""
  ) {
    self.name = name
    self.initialPrompt = initialPrompt
    self.providerID = providerID
    self.modelID = modelID
    self.appearance = appearance
    self.workingDirectoryPath = workingDirectoryPath
    self.templateFill = templateFill
    self.ticketText = ticketText
  }

  /// The name of the template field that names the ticket, whatever its case.
  public static let ticketFieldName = "ticket"

  /// The ticket the session starts with: the one typed, else the one the template's `ticket` field
  /// names. `#12` needs the repository the session works in to become an address.
  public func ticket(repository: RepositoryWebAddress?) -> SessionTicket? {
    if let url = TicketInput.url(from: ticketText, repository: repository) {
      return SessionTicket(url: url, source: .manual)
    }
    guard let templateFill,
      let field = templateFill.template.fields.first(where: {
        $0.name.lowercased() == Self.ticketFieldName
      }),
      let url = TicketInput.url(
        from: templateFill.value(for: field.name), repository: repository)
    else { return nil }
    return SessionTicket(url: url, source: .template)
  }

  public var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The prompt the agent is sent: the template's rendering, or what was typed.
  public var effectivePrompt: String {
    templateFill?.render().prompt ?? PromptText.normalizingLineBreaks(initialPrompt)
  }

  public var trimmedPrompt: String {
    effectivePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var effectiveAppearance: SessionAppearance {
    appearance ?? SessionAppearanceCatalog.derived(forName: name)
  }

  public var resolvedWorkingDirectoryPath: String? {
    guard let path = workingDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
      !path.isEmpty
    else {
      return nil
    }
    return (path as NSString).expandingTildeInPath
  }

  /// The problems visible without touching the disk or the agents.
  ///
  /// All of them at once, never the first one: a form that reveals its problems one by one makes
  /// the user press Create three times to learn three things.
  public func validate() -> [SessionDraftIssue] {
    var issues: [SessionDraftIssue] = []

    if trimmedName.isEmpty {
      issues.append(.nameMissing)
    }
    if let path = resolvedWorkingDirectoryPath {
      if !path.hasPrefix("/") {
        issues.append(.workingDirectoryNotAbsolute)
      }
    } else {
      issues.append(.workingDirectoryMissing)
    }
    if providerID?.isEmpty ?? true {
      issues.append(.agentMissing)
    }
    if let templateFill {
      issues += templateFill.missingRequiredFields.map(SessionDraftIssue.templateFieldMissing)
    } else if PromptText.containsForbiddenCharacters(
      PromptText.normalizingLineBreaks(initialPrompt))
    {
      issues.append(.promptControlCharacters)
    }
    if !isStorableAppearance {
      issues.append(.appearanceInvalid)
    }
    return issues
  }

  /// The session this draft becomes. Callers pass a validated draft; the value is still checked
  /// by `WorkSession.validate()` before it reaches the store.
  public func session(
    id: SessionID = SessionID(),
    createdAt: Date = Date(),
    repository: RepositoryWebAddress? = nil
  ) -> WorkSession {
    WorkSession(
      id: id,
      name: trimmedName,
      initialPrompt: effectivePrompt,
      agent: providerID.map { SessionAgentConfiguration(providerID: $0, modelID: modelID) },
      appearance: effectiveAppearance,
      status: .closed,
      createdAt: createdAt,
      updatedAt: createdAt,
      closedAt: createdAt,
      repositories: resolvedWorkingDirectoryPath.map { [RepositoryContext(path: $0)] } ?? [],
      // The rendered text is what the session keeps; the template is only where it came from.
      template: templateFill?.reference,
      ticket: ticket(repository: repository)
    )
  }

  private var isStorableAppearance: Bool {
    let appearance = effectiveAppearance
    guard !appearance.symbolName.isEmpty else { return false }
    let color = appearance.colorHex
    guard color.count == 7 || color.count == 9, color.first == "#" else { return false }
    return color.dropFirst().allSatisfy(\.isHexDigit)
  }
}
