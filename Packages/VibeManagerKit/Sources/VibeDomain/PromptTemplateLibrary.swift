import Foundation

/// The user's templates, in the order they chose, and what can be done to them.
///
/// A value: the store applies these to what it holds, and the tests to what they build.
public struct PromptTemplateLibrary: Hashable, Sendable {
  /// Active and archived alike, in the order shown; the archived ones are listed apart.
  public private(set) var templates: [PromptTemplate]

  public init(templates: [PromptTemplate] = []) {
    self.templates = templates
  }

  public var active: [PromptTemplate] {
    templates.filter { !$0.isArchived }
  }

  public var archived: [PromptTemplate] {
    templates.filter(\.isArchived)
  }

  public func template(id: PromptTemplateID) -> PromptTemplate? {
    templates.first { $0.id == id }
  }

  /// Stores `template`: a new one goes to the end at revision 1, a known one takes the next
  /// revision. Only the settings of fields still in the text are kept.
  @discardableResult
  public mutating func save(_ template: PromptTemplate, at date: Date) throws -> PromptTemplate {
    var saved = template
    saved.name = template.trimmedName
    saved.fieldSettings = template.trimmedFieldSettings
    let others = templates.filter { $0.id != template.id }
    let problems = saved.problems(among: others)
    guard problems.isEmpty else { throw PromptTemplateRejected(issues: problems) }

    if let index = templates.firstIndex(where: { $0.id == template.id }) {
      saved.revision = templates[index].revision + 1
      saved.createdAt = templates[index].createdAt
      saved.archivedAt = templates[index].archivedAt
      saved.updatedAt = date.storageRounded
      templates[index] = saved
    } else {
      saved.revision = 1
      saved.createdAt = date.storageRounded
      saved.updatedAt = date.storageRounded
      templates.append(saved)
    }
    return saved
  }

  /// A copy placed right after the original, under a name of its own.
  @discardableResult
  public mutating func duplicate(
    _ id: PromptTemplateID, as newID: PromptTemplateID = PromptTemplateID(), at date: Date
  ) -> PromptTemplate? {
    guard let index = templates.firstIndex(where: { $0.id == id }) else { return nil }
    let original = templates[index]
    let copy = PromptTemplate(
      id: newID,
      name: uniqueName(startingWith: "\(original.trimmedName) copy"),
      sessionNamePattern: original.sessionNamePattern,
      body: original.body,
      fieldSettings: original.fieldSettings,
      revision: 1,
      createdAt: date
    )
    templates.insert(copy, at: index + 1)
    return copy
  }

  /// Moves an active template to `position` among the active ones.
  public mutating func move(_ id: PromptTemplateID, toActivePosition position: Int) {
    guard let from = templates.firstIndex(where: { $0.id == id }), !templates[from].isArchived
    else { return }
    let template = templates.remove(at: from)
    let activeIndices = templates.indices.filter { !templates[$0].isArchived }
    let clamped = max(0, min(position, activeIndices.count))
    let destination =
      clamped < activeIndices.count
      ? activeIndices[clamped] : (activeIndices.last.map { $0 + 1 } ?? templates.count)
    templates.insert(template, at: destination)
  }

  /// One place up or down among the active templates.
  public mutating func move(_ id: PromptTemplateID, by offset: Int) {
    guard let position = active.firstIndex(where: { $0.id == id }) else { return }
    move(id, toActivePosition: position + offset)
  }

  public mutating func archive(_ id: PromptTemplateID, at date: Date) {
    guard let index = templates.firstIndex(where: { $0.id == id }),
      !templates[index].isArchived
    else { return }
    templates[index].archivedAt = date.storageRounded
  }

  /// Back among the active ones, last — under another name if its own was taken meanwhile.
  public mutating func unarchive(_ id: PromptTemplateID) {
    guard let index = templates.firstIndex(where: { $0.id == id }), templates[index].isArchived
    else { return }
    var template = templates.remove(at: index)
    template.archivedAt = nil
    template.name = uniqueName(startingWith: template.trimmedName)
    templates.append(template)
  }

  /// Only an archived template can be deleted: destroying one takes two gestures.
  @discardableResult
  public mutating func delete(_ id: PromptTemplateID) -> Bool {
    guard let index = templates.firstIndex(where: { $0.id == id }), templates[index].isArchived
    else { return false }
    templates.remove(at: index)
    return true
  }

  /// Adds the examples that are not here, active or archived. Their identifiers are fixed, so
  /// asking twice adds nothing, and nothing but this gesture ever adds them.
  @discardableResult
  public mutating func addExamples(at date: Date) -> [PromptTemplate] {
    var added: [PromptTemplate] = []
    for example in PromptTemplateExamples.all(createdAt: date)
    where template(id: example.id) == nil {
      var example = example
      example.name = uniqueName(startingWith: example.name)
      templates.append(example)
      added.append(example)
    }
    return added
  }

  public var isMissingExamples: Bool {
    PromptTemplateExamples.identifiers.contains { template(id: $0) == nil }
  }

  /// `base`, or `base 2`, `base 3`… — the first no active template is called.
  public func uniqueName(startingWith base: String) -> String {
    let taken = Set(active.map { $0.trimmedName.lowercased() })
    guard taken.contains(base.lowercased()) else { return base }
    var number = 2
    while taken.contains("\(base) \(number)".lowercased()) {
      number += 1
    }
    return "\(base) \(number)"
  }

  // MARK: - Import

  /// What importing `incoming` would do, template by template, without doing it.
  public func planImport(_ incoming: [PromptTemplate]) -> PromptTemplateImportPlan {
    var entries: [PromptTemplateImportPlan.Entry] = []
    var seen: Set<PromptTemplateID> = []
    for template in incoming {
      guard seen.insert(template.id).inserted else {
        entries.append(
          .init(template: template, outcome: .skipped("It appears twice in the file.")))
        continue
      }
      let problems = template.problems(among: [])
      if let first = problems.first {
        entries.append(.init(template: template, outcome: .skipped(first.message)))
        continue
      }
      if let existing = self.template(id: template.id) {
        entries.append(
          .init(
            template: template,
            outcome: existing.hasSameContent(as: template) ? .identical : .changed))
      } else {
        entries.append(.init(template: template, outcome: .new))
      }
    }
    return PromptTemplateImportPlan(entries: entries)
  }

  /// Applies a plan. A changed template is kept beside the existing one unless `replacing`
  /// names it; a replaced one takes a new revision, and the sessions keep theirs.
  @discardableResult
  public mutating func apply(
    _ plan: PromptTemplateImportPlan,
    replacing: Set<PromptTemplateID> = [],
    at date: Date,
    makeID: () -> PromptTemplateID = { PromptTemplateID() }
  ) -> Int {
    var imported = 0
    for entry in plan.entries {
      var template = entry.template
      template.fieldSettings = template.trimmedFieldSettings
      switch entry.outcome {
      case .identical, .skipped:
        continue
      case .changed where replacing.contains(template.id):
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { continue }
        let existing = templates[index]
        template.name = uniqueName(
          startingWith: template.trimmedName, ignoring: existing.id)
        template.revision = existing.revision + 1
        template.createdAt = existing.createdAt
        template.updatedAt = date.storageRounded
        templates[index] = template
      case .changed:
        template = PromptTemplate(
          id: makeID(),
          name: uniqueName(startingWith: template.trimmedName),
          sessionNamePattern: template.sessionNamePattern,
          body: template.body,
          fieldSettings: template.fieldSettings,
          createdAt: date,
          archivedAt: template.archivedAt.map { _ in date }
        )
        templates.append(template)
      case .new:
        template = PromptTemplate(
          id: template.id,
          name: template.isArchived
            ? template.trimmedName : uniqueName(startingWith: template.trimmedName),
          sessionNamePattern: template.sessionNamePattern,
          body: template.body,
          fieldSettings: template.fieldSettings,
          createdAt: date,
          archivedAt: template.archivedAt.map { _ in date }
        )
        templates.append(template)
      }
      imported += 1
    }
    return imported
  }

  private func uniqueName(startingWith base: String, ignoring id: PromptTemplateID) -> String {
    var library = self
    library.templates.removeAll { $0.id == id }
    return library.uniqueName(startingWith: base)
  }
}

public struct PromptTemplateRejected: Error, Equatable, Sendable {
  public let issues: [PromptTemplateIssue]

  public init(issues: [PromptTemplateIssue]) {
    self.issues = issues
  }
}

/// What an import would do, shown before it is done.
public struct PromptTemplateImportPlan: Hashable, Sendable {
  public enum Outcome: Hashable, Sendable {
    case new
    /// Already here, word for word: nothing to import.
    case identical
    /// Already here under the same identifier, but different.
    case changed
    case skipped(String)
  }

  public struct Entry: Hashable, Sendable, Identifiable {
    public let template: PromptTemplate
    public let outcome: Outcome

    public init(template: PromptTemplate, outcome: Outcome) {
      self.template = template
      self.outcome = outcome
    }

    public var id: PromptTemplateID { template.id }
  }

  public let entries: [Entry]

  public init(entries: [Entry]) {
    self.entries = entries
  }

  public var changed: [Entry] {
    entries.filter { $0.outcome == .changed }
  }

  /// Whether applying the plan would add or change anything.
  public var hasWork: Bool {
    entries.contains { $0.outcome == .new || $0.outcome == .changed }
  }
}
