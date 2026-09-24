import Foundation
import Observation
import VibeApplication
import VibeDomain

/// The prompt templates for the length of the run: the list the window and the New Session sheet
/// read, and the one template being edited.
///
/// Editing is saved explicitly, unlike the notes: a template half typed must not be offered in
/// the sheet, and each save is a revision the sessions created from it record.
@MainActor
@Observable
public final class PromptTemplateLibraryModel {
  public enum LoadState: Equatable {
    case loading
    case ready
    /// The file could not be read. Nothing is written over it until it is dealt with.
    case unreadable(String)
  }

  /// An import waiting for the user to look at it.
  public struct PendingImport: Equatable, Sendable {
    public let plan: PromptTemplateImportPlan
    /// The changed templates to replace rather than keep beside the existing ones.
    public var replacing: Set<PromptTemplateID> = []
  }

  public private(set) var state: LoadState = .loading
  public private(set) var library = PromptTemplateLibrary()
  public private(set) var selectedID: PromptTemplateID?
  /// The selected template as it is being edited. A template never saved is only here.
  public var editing: PromptTemplate?
  /// Values tried in the preview. Never saved.
  public var sampleValues: [String: String] = [:]
  /// The last save, import or export that failed, in a sentence.
  public private(set) var failure: String?
  /// Where to go once the user has said what to do with the changes to this template.
  public enum Navigation: Equatable, Sendable {
    case select(PromptTemplateID?)
    case newTemplate
  }

  /// Held while the question is asked. The dialog's buttons are handed it rather than reading it
  /// back: SwiftUI dismisses a dialog before it runs the button, and the dismissal clears this.
  public private(set) var pendingNavigation: Navigation?
  public var pendingImport: PendingImport?
  /// Said after an import, until dismissed.
  public private(set) var importSummary: String?

  /// Called with every library that was written, for the New Session sheet.
  public var libraryDidChange: ((PromptTemplateLibrary) -> Void)?

  private let repository: any PromptTemplateRepository
  private let clock: any SessionClock
  private let exchange: (any PromptTemplateExchangeFormat)?
  private var hasLoaded = false

  public init(
    repository: any PromptTemplateRepository,
    exchange: (any PromptTemplateExchangeFormat)? = nil,
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.repository = repository
    self.exchange = exchange
    self.clock = clock
  }

  public var fileURL: URL? {
    repository.fileURL
  }

  /// Every template, in the user's order.
  public var all: [PromptTemplate] {
    library.templates
  }

  public var isReadOnly: Bool {
    if case .unreadable = state { return true }
    return false
  }

  /// The stored version of the template being edited, `nil` for one never saved.
  public var savedEditing: PromptTemplate? {
    editing.flatMap { library.template(id: $0.id) }
  }

  public var isNew: Bool {
    editing != nil && savedEditing == nil
  }

  public var isEdited: Bool {
    guard let editing else { return false }
    guard let saved = savedEditing else { return true }
    return !saved.hasSameContent(as: editing)
  }

  /// Everything that keeps the template being edited from being saved.
  public var issues: [PromptTemplateIssue] {
    guard let editing else { return [] }
    return editing.problems(among: library.templates.filter { $0.id != editing.id })
  }

  public var canSave: Bool {
    !isReadOnly && isEdited && issues.isEmpty
  }

  /// What the template being edited gives with the sample values.
  public var preview: RenderedPrompt? {
    editing.map { PromptTemplateFill(template: $0, values: sampleValues).render() }
  }

  public func load() async {
    guard !hasLoaded else { return }
    hasLoaded = true
    await reload()
  }

  public func reload() async {
    do {
      library = try await repository.library()
      state = .ready
    } catch {
      state = .unreadable(Self.sentence(error))
    }
    if let selectedID, library.template(id: selectedID) == nil, !isNew {
      select(nil)
    }
  }

  // MARK: - Selection

  /// Goes to another template, or asks first when this one has changes.
  public func requestSelect(_ id: PromptTemplateID?) {
    guard id != selectedID else { return }
    if isEdited {
      pendingNavigation = .select(id)
      return
    }
    select(id)
  }

  /// The answer to the question: `saving` writes the changes first, and a save that fails stays
  /// where it is, with its reason.
  public func resolve(_ navigation: Navigation, saving: Bool) async {
    pendingNavigation = nil
    if saving {
      guard await save() else { return }
    }
    switch navigation {
    case .select(let id): select(id)
    case .newTemplate: startNewTemplate()
    }
  }

  /// The question was dismissed: nothing changes.
  public func dismissPendingNavigation() {
    pendingNavigation = nil
  }

  private func select(_ id: PromptTemplateID?) {
    selectedID = id
    editing = id.flatMap { library.template(id: $0) }
    sampleValues = [:]
    failure = nil
  }

  // MARK: - Editing

  /// A new template, once the changes to this one are dealt with.
  public func newTemplate() {
    guard !isReadOnly else { return }
    if isEdited {
      pendingNavigation = .newTemplate
      return
    }
    startNewTemplate()
  }

  private func startNewTemplate() {
    let template = PromptTemplate(
      name: library.uniqueName(startingWith: "Untitled Template"), body: "",
      createdAt: clock.now())
    selectedID = template.id
    editing = template
    sampleValues = [:]
  }

  /// Writes the template being edited as a new revision. `false` when it could not be.
  @discardableResult
  public func save() async -> Bool {
    guard let editing, canSave else { return false }
    let now = clock.now()
    do {
      let (library, saved) = try await repository.update { library in
        try library.save(editing, at: now)
      }
      publish(library)
      // What was typed while the write was under way is kept: it is only replaced when it is
      // still the text that was saved.
      if self.editing == editing {
        self.editing = saved
      }
      selectedID = saved.id
      failure = nil
      return true
    } catch {
      failure = Self.sentence(error)
      return false
    }
  }

  public func revert() {
    guard let editing else { return }
    if let saved = library.template(id: editing.id) {
      self.editing = saved
    } else {
      select(nil)
    }
  }

  /// Makes a field required or optional, by its `?` in the text.
  public func setRequired(_ isRequired: Bool, for key: String) {
    editing?.setRequired(isRequired, for: key)
  }

  public func updateSettings(for key: String, _ change: (inout PromptTemplateFieldSettings) -> Void)
  {
    editing?.updateSettings(for: key, change)
  }

  // MARK: - The list

  public func duplicate(_ id: PromptTemplateID) async {
    let now = clock.now()
    if let copy = await change({ $0.duplicate(id, at: now) }) ?? nil {
      requestSelect(copy.id)
    }
  }

  public func move(_ id: PromptTemplateID, toPosition position: Int) async {
    await change { $0.move(id, toPosition: position) }
  }

  public func move(_ id: PromptTemplateID, by offset: Int) async {
    await change { $0.move(id, by: offset) }
  }

  public func canMove(_ id: PromptTemplateID, by offset: Int) -> Bool {
    guard let index = all.firstIndex(where: { $0.id == id }) else { return false }
    return all.indices.contains(index + offset)
  }

  public func delete(_ id: PromptTemplateID) async {
    await change { $0.delete(id) }
    if selectedID == id { select(nil) }
  }

  public var canAddExamples: Bool {
    !isReadOnly && library.isMissingExamples
  }

  public func addExamples() async {
    let now = clock.now()
    if let added = await change({ $0.addExamples(at: now) }), let first = added.first {
      requestSelect(first.id)
    }
  }

  // MARK: - Exchange

  public var canExchange: Bool {
    exchange != nil
  }

  /// The file to export `ids`, or every template.
  public func exportData(ids: Set<PromptTemplateID>? = nil) -> Data? {
    guard let exchange else { return nil }
    let chosen = library.templates.filter { ids?.contains($0.id) ?? true }
    do {
      failure = nil
      return try exchange.encode(chosen, exportedAt: clock.now())
    } catch {
      failure = Self.sentence(error)
      return nil
    }
  }

  /// Reads a file and lays out what importing it would do, without doing it.
  public func prepareImport(_ data: Data) {
    guard !isReadOnly, let exchange else { return }
    do {
      let incoming = try exchange.decode(data, importedAt: clock.now())
      pendingImport = PendingImport(plan: library.planImport(incoming))
      failure = nil
    } catch {
      failure = Self.sentence(error)
    }
  }

  public func applyImport() async {
    guard let pending = pendingImport else { return }
    pendingImport = nil
    let now = clock.now()
    if let count = await change({ $0.apply(pending.plan, replacing: pending.replacing, at: now) }) {
      importSummary =
        count == 0
        ? "Nothing to import: every template is already here."
        : count == 1 ? "1 template imported." : "\(count) templates imported."
    }
  }

  public func cancelImport() {
    pendingImport = nil
  }

  public func dismissImportSummary() {
    importSummary = nil
  }

  public func dismissFailure() {
    failure = nil
  }

  // MARK: -

  @discardableResult
  private func change<Result: Sendable>(
    _ transform: @escaping @Sendable (inout PromptTemplateLibrary) -> Result
  ) async -> Result? {
    guard !isReadOnly else { return nil }
    do {
      let (library, result) = try await repository.update { library in
        transform(&library)
      }
      publish(library)
      failure = nil
      return result
    } catch {
      failure = Self.sentence(error)
      return nil
    }
  }

  private func publish(_ library: PromptTemplateLibrary) {
    self.library = library
    state = .ready
    libraryDidChange?(library)
  }

  static func sentence(_ error: any Error) -> String {
    if let rejected = error as? PromptTemplateRejected, let first = rejected.issues.first {
      return "\(first.message) \(first.remedy)"
    }
    return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}
