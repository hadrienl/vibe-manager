import Foundation
import Observation
import VibeApplication

/// The list of skills and commands under a `/` typed first, for one place a prompt is written: the
/// composer of a conversation, or the initial prompt of a new session (#219).
///
/// Its state follows the text it is told of, as the shell mode does (#188): the list is open while
/// the whole text is a trigger and a name, until Escape closes it for that command.
@MainActor
@Observable
public final class ComposerCommands {
  /// Reads what the agent accepts: the list kept, read again when it is stale. `nil` for an agent
  /// that cannot list them — `/` is then text.
  @ObservationIgnored public var read: (() async -> AgentCommandIndex?)? {
    didSet {
      // A reading under way was for the reader before: what it brings is dropped.
      reading?.cancel()
      reading = nil
      isReading = false
      generation += 1
      if read == nil {
        index = AgentCommandIndex([])
      } else if query != nil {
        // Given while a command is being typed: read now, for the list to open.
        refresh()
      }
    }
  }
  /// What the agent accepts, as last read.
  public private(set) var index = AgentCommandIndex([]) {
    didSet { update() }
  }
  /// The list, in the order shown; `nil` while it is closed. Empty when nothing matches: it stays
  /// open to say so.
  public private(set) var suggestions: [AgentCommandMatch]?
  public private(set) var selectedIndex = 0
  /// Whether the list is being read, the first time: it opens then, and says so, rather than
  /// staying away for as long as the CLI takes to answer.
  public private(set) var isReading = false

  @ObservationIgnored private var text = ""
  @ObservationIgnored private var isEnabled = false
  /// The command being typed when the list was last worked out: the selection goes back to the
  /// first entry when it changes.
  @ObservationIgnored private var query: AgentCommandQuery?
  /// The text Escape closed the list on: it stays closed while that command is typed, and opens
  /// again once erased back to its `/`, or at the next one.
  @ObservationIgnored private var dismissedText: String?
  /// The command last inserted, with its arguments' hint, while the text still opens on it.
  @ObservationIgnored private var inserted: AgentCommand?
  @ObservationIgnored private var reading: Task<Void, Never>?
  @ObservationIgnored private var generation = 0

  public init() {}

  public var isShowing: Bool { suggestions != nil }

  /// The text changed, or whether a prompt can be written now.
  public func update(text: String, isEnabled: Bool) {
    guard text != self.text || isEnabled != self.isEnabled else { return }
    self.text = text
    self.isEnabled = isEnabled
    update()
  }

  /// Reads the list again, in the background.
  public func refresh() {
    guard reading == nil, let read else { return }
    let generation = generation
    isReading = true
    reading = Task { [weak self] in
      let index = await read()
      guard let self, self.generation == generation else { return }
      self.reading = nil
      self.isReading = false
      if let index {
        self.index = index
      } else {
        self.update()
      }
    }
  }

  private func update() {
    let query = AgentCommandQuery(draft: text, triggers: index.triggers)
    defer { self.query = query }
    if let command = inserted, !opens(on: command) { inserted = nil }
    if let dismissed = dismissedText {
      let erasedToTrigger =
        query?.text.isEmpty == true
        && AgentCommandQuery(draft: dismissed, triggers: index.triggers)?.text.isEmpty == false
      guard query == nil || erasedToTrigger else {
        close()
        return
      }
      dismissedText = nil
    }
    guard let query, read != nil, isEnabled else {
      close()
      return
    }
    // Opening: what was read is shown at once, and read again behind it.
    if self.query == nil { refresh() }
    guard !index.isEmpty else {
      // Nothing read yet: open, saying the list is on its way.
      if isReading, suggestions != [] { suggestions = [] } else if !isReading { close() }
      return
    }
    let matches = index.matches(for: query)
    if query != self.query || suggestions == nil {
      selectedIndex = 0
    } else {
      selectedIndex = min(selectedIndex, max(matches.count - 1, 0))
    }
    suggestions = matches
  }

  private func close() {
    if suggestions != nil { suggestions = nil }
  }

  /// ↑ or ↓ while the list is open. Returns whether the key was used.
  public func moveSelection(by offset: Int) -> Bool {
    guard let matches = suggestions else { return false }
    guard !matches.isEmpty else { return true }
    selectedIndex = min(max(selectedIndex + offset, 0), matches.count - 1)
    return true
  }

  /// The entry ⇥ or ↩ would insert: none while the list is closed or nothing matches.
  public var selectedCommand: AgentCommand? {
    guard let matches = suggestions, matches.indices.contains(selectedIndex) else { return nil }
    return matches[selectedIndex].command
  }

  /// The text once `command` replaces what was typed: its invocation and a space.
  /// Whether ↩ inserts the entry selected: only to complete a name begun. Found by its description
  /// only, or with a name typed in full, ↩ sends the text as typed; ⇥ always inserts.
  public var returnInserts: Bool {
    guard let command = selectedCommand, let query else { return false }
    return index.completes(query, with: command)
  }

  public func inserting(_ command: AgentCommand) -> String {
    inserted = command
    return AgentCommandQuery.draft(inserting: command, into: text)
  }

  /// Escape while the list is open: it closes, the text left as it is.
  public func dismiss() -> Bool {
    guard isShowing else { return false }
    dismissedText = text
    close()
    return true
  }

  /// A text put back from elsewhere — the history — opens no list: ↑ and ↓ keep walking it.
  public func willShowRecalled(_ text: String) {
    dismissedText = AgentCommandQuery(draft: text, triggers: index.triggers).map { _ in text }
  }

  /// The command the text opens on, as inserted from the list: shown as a token.
  public var insertedInvocation: String? {
    inserted.flatMap { opens(on: $0) ? $0.invocation : nil }
  }

  /// What the command inserted expects, dimmed after it until something is typed.
  public var pendingArgumentHint: String? {
    guard let command = inserted, text == AgentCommandQuery.draft(inserting: command, into: text)
    else { return nil }
    return command.argumentHint
  }

  private func opens(on command: AgentCommand) -> Bool {
    text.drop { $0 == " " || $0 == "\t" }.hasPrefix(command.invocation + " ")
  }
}
