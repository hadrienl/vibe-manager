import Foundation

/// The messages the user sent in a session, oldest first, as ↑ and ↓ recall them in the
/// composer (#123).
///
/// Derived, never stored: read from the transcript — which holds the prompts typed in the terminal
/// and those of earlier launches, and survives a restart — then from the prompts sent from the
/// composer that the transcript does not hold yet.
public struct PromptHistory: Hashable, Sendable {
  public let prompts: [String]

  /// - Parameters:
  ///   - entries: the conversation as read from the transcript.
  ///   - pending: prompts sent that the transcript does not hold yet, in the order sent.
  public init(entries: [ConversationEntry], pending: [String] = []) {
    let written = entries.compactMap { entry -> String? in
      guard case .userPrompt(let text, _) = entry.content else { return nil }
      return text
    }
    var prompts: [String] = []
    for text in written + pending {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed != prompts.last else { continue }
      prompts.append(trimmed)
    }
    self.prompts = prompts
  }

  public init(prompts: [String]) {
    self.init(entries: [], pending: prompts)
  }
}

/// Where ↑ and ↓ stand in a `PromptHistory`, and the draft they put aside (#123).
///
/// The draft is never lost: put aside at the first ↑, it comes back below the most recent message,
/// or on Escape. A message recalled then edited is a draft of its own — the history is left as it
/// was, and the next ↑ puts that text aside in turn.
public struct PromptHistoryNavigation: Hashable, Sendable {
  /// The message shown, counted from the oldest: a message arriving at the end meanwhile moves
  /// nothing. `nil` outside a navigation.
  public private(set) var index: Int?
  /// The draft as it was at the first ↑.
  public private(set) var savedDraft: String?

  public init() {}

  public var isNavigating: Bool { index != nil }

  /// ↑: the older message to show, or `nil` when there is none, and the key does its usual work.
  public mutating func older(in history: PromptHistory, draft: String) -> String? {
    let prompts = history.prompts
    guard let current = currentIndex(in: history, draft: draft) else {
      guard let last = prompts.indices.last else { return nil }
      savedDraft = draft
      index = last
      return prompts[last]
    }
    guard current > 0 else { return nil }
    index = current - 1
    return prompts[current - 1]
  }

  /// ↓: the next message, or the draft put aside past the most recent one, which ends the
  /// navigation. `nil` outside a navigation.
  public mutating func newer(in history: PromptHistory, draft: String) -> String? {
    guard let current = currentIndex(in: history, draft: draft) else { return nil }
    let prompts = history.prompts
    guard current + 1 < prompts.count else { return end() }
    index = current + 1
    return prompts[current + 1]
  }

  /// Escape: the draft put aside, which ends the navigation. `nil` outside a navigation — a
  /// recalled message edited included, which is the draft now.
  public mutating func cancel(in history: PromptHistory, draft: String) -> String? {
    guard currentIndex(in: history, draft: draft) != nil else { return nil }
    return end()
  }

  private mutating func end() -> String {
    defer { self = PromptHistoryNavigation() }
    return savedDraft ?? ""
  }

  /// The message shown, if the composer still shows it as recalled. Edited, it is a draft: the
  /// navigation ends, and the next ↑ starts again from the most recent message.
  private mutating func currentIndex(in history: PromptHistory, draft: String) -> Int? {
    guard let index else { return nil }
    let prompts = history.prompts
    let shown = min(index, prompts.count - 1)
    guard shown >= 0, prompts[shown] == draft else {
      self = PromptHistoryNavigation()
      return nil
    }
    self.index = shown
    return shown
  }
}
