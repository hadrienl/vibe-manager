import Foundation
import VibeApplication

/// Claude Code's dialogs, as drawn by 2.1.282 (#40) and 2.1.285 (#273).
///
/// - A permission: `1. Yes` / `2. Yes, and always allow…` — only when the request carries
///   `permission_suggestions` — / `3. No`. Escape refuses whatever the options are: a digit for
///   "No" guessed one place off would allow instead. 2.1.247 may add `Yes, and switch to auto
///   mode`, and the options of a sandboxed command's network access are other words again: the
///   digits are read off the screen.
/// - Questions: a digit picks its option and moves on; the one after the options is "Type
///   something.", which takes pasted text and Return. A question of several choices is a list of
///   boxes, as drawn by 2.1.283: a digit ticks its option and stays, the right arrow moves on.
///   Several questions, or one of several choices, end on a review, whose `1` submits. Beside
///   previews, as drawn by 2.1.285, a digit only moves the highlight: Return, sent apart, takes it.
/// - A plan: `Yes, auto-accept edits` — or `Yes, and use auto mode` where that mode is available,
///   in its place — then `Yes, manually approve edits`; a setting may put `clear context`
///   options before them. The option is read off the screen; Escape rejects.
///
/// Return is never pressed alone to pick an option: it takes the highlighted one, whatever that
/// is. It follows a digit only beside previews, once the digit has moved the highlight.
public struct ClaudeCodeAnswerKeymap: AgentAnswerKeymap {
  public init() {}

  public func answers(for content: AgentRequestContent) -> Set<AgentAnswerKind> {
    switch content {
    case .permission(let permission):
      return permission.alwaysAllow == nil
        ? [.allowOnce, .deny] : [.allowOnce, .allowAlways, .deny]
    case .questions(let questions):
      // Past nine options, the free answer has no digit.
      guard questions.allSatisfy({ TerminalKeys.digit(forOption: $0.options.count) != nil })
      else { return [] }
      return questions.contains(where: \.allowsMultipleChoices)
        ? [.chooseOption, .chooseOptions, .writeText] : [.chooseOption, .writeText]
    case .plan:
      return [.approvePlan, .rejectPlan]
    case .unreadable:
      return [.deny]
    case .elicitation, .inTerminal:
      return []
    }
  }

  public func keystrokes(
    for answer: AgentAnswer, to content: AgentRequestContent, screen: AgentDialogScreen?
  ) -> [[UInt8]]? {
    switch (answer, content) {
    case (.allowOnce, .permission):
      return Self.digit(of: screen?.option { $0 == "Yes" })
    case (.allowAlways, .permission(let permission)) where permission.alwaysAllow != nil:
      // Never an option that changes the permission mode for the whole session.
      return Self.digit(
        of: screen?.option {
          $0.hasPrefix("Yes, ") && !$0.localizedCaseInsensitiveContains("auto mode")
            && !$0.localizedCaseInsensitiveContains("bypass")
        })
    case (.deny, .permission), (.deny, .unreadable), (.rejectPlan, .plan):
      return [TerminalKeys.escape]
    case (.approvePlan(let approval), .plan):
      let words: String
      switch approval {
      case .acceptEdits: words = "auto-accept edits"
      case .autoMode: words = "auto mode"
      case .reviewEdits: words = "manually approve edits"
      }
      // The options that also clear the context are never taken for these.
      return Self.digit(
        of: screen?.option {
          $0.hasPrefix("Yes") && $0.localizedCaseInsensitiveContains(words)
            && !$0.localizedCaseInsensitiveContains("clear context")
        })
    case (.answers(let answers), .questions(let questions)):
      guard answers.count == questions.count else { return nil }
      var steps: [[UInt8]] = []
      for (answer, question) in zip(answers, questions) {
        guard let keys = Self.keystrokes(for: answer, to: question) else { return nil }
        steps += keys
      }
      // Several questions, or one of several choices, end on a review of the answers: its first
      // option submits them.
      if questions.count > 1 || questions.contains(where: \.allowsMultipleChoices) {
        steps.append(Array("1".utf8))
      }
      return steps
    default:
      return nil
    }
  }

  /// The digit of an option read on screen.
  static func digit(of option: AgentDialogScreen.Option?) -> [[UInt8]]? {
    option.flatMap { TerminalKeys.digit(forOption: $0.number - 1) }.map { [$0] }
  }

  static func keystrokes(for answer: AgentQuestionAnswer, to question: AgentQuestion)
    -> [[UInt8]]?
  {
    if question.allowsMultipleChoices {
      // Each digit ticks a box; the right arrow leaves the question.
      let indices: Set<Int>
      switch answer {
      case .option(let index): indices = [index]
      case .options(let chosen): indices = chosen
      case .text: return nil
      }
      guard !indices.isEmpty, indices.allSatisfy(question.options.indices.contains) else {
        return nil
      }
      let ticks = indices.sorted().compactMap { TerminalKeys.digit(forOption: $0) }
      guard ticks.count == indices.count else { return nil }
      return ticks + [TerminalKeys.rightArrow]
    }
    switch answer {
    case .option(let index):
      guard question.options.indices.contains(index),
        let digit = TerminalKeys.digit(forOption: index)
      else { return nil }
      // Beside previews, a digit only moves the highlight (2.1.285): Return takes it, sent apart
      // so that the dialog has moved first.
      return question.showsPreviews ? [digit, TerminalKeys.enter] : [digit]
    case .text(let text):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, question.allowsFreeText,
        let other = TerminalKeys.digit(forOption: question.options.count)
      else { return nil }
      return [other, TerminalKeys.bracketedPaste(trimmed), TerminalKeys.enter]
    case .options:
      return nil
    }
  }
}

/// Codex's approval dialogs, as drawn by 0.157.1 (#40) and 0.159.2 (#273): each option shows its
/// key — `(y)` runs it once, `(p)` stops asking for commands that start the same way, `(a)` for
/// the rest of the session, the files of a patch or a host for the conversation; Escape refuses.
/// The keys are taken from the screen: `p` is drawn only when Codex proposes a prefix, and in the
/// dialog of a network access it allows the host for good. Its questions are reported before they
/// are drawn, and are answered in the terminal.
///
/// A tool of an MCP server is approved in another dialog, a form whose one field lists `Allow`
/// first, then — only when the server allows it — `Allow for this session` and `Always allow`,
/// then `Cancel`. It ignores `y`, which left the agent waiting on a request the card said was
/// answered: a digit picks its option and submits the form, and `1` is always `Allow`.
public struct CodexAnswerKeymap: AgentAnswerKeymap {
  public init() {}

  public func answers(for content: AgentRequestContent) -> Set<AgentAnswerKind> {
    switch content {
    case .permission(let permission):
      // A host's access says nothing of commands: no "always" there, whatever the tool.
      return Self.alwaysKey(for: permission) == nil || permission.alwaysAllow == nil
        ? [.allowOnce, .deny] : [.allowOnce, .allowAlways, .deny]
    case .unreadable:
      return [.deny]
    case .questions, .plan, .elicitation, .inTerminal:
      return []
    }
  }

  public func keystrokes(
    for answer: AgentAnswer, to content: AgentRequestContent, screen: AgentDialogScreen?
  ) -> [[UInt8]]? {
    switch (answer, content) {
    case (.allowOnce, .permission(let permission)):
      if case .mcp = permission.tool {
        return ClaudeCodeAnswerKeymap.digit(of: screen?.option { $0 == "Allow" })
      }
      return Self.shortcut("y", in: screen)
    case (.allowAlways, .permission(let permission)):
      guard permission.alwaysAllow != nil, let key = Self.alwaysKey(for: permission),
        let option = screen?.options.first(where: { $0.shortcut == String(decoding: key, as: UTF8.self) }),
        !option.label.localizedCaseInsensitiveContains("in the future")
      else { return nil }
      return [key]
    case (.deny, .permission), (.deny, .unreadable):
      return [TerminalKeys.escape]
    default:
      return nil
    }
  }

  /// `key`, when an option on screen shows it.
  static func shortcut(_ key: String, in screen: AgentDialogScreen?) -> [[UInt8]]? {
    guard screen?.options.contains(where: { $0.shortcut == key }) == true else { return nil }
    return [Array(key.utf8)]
  }

  static func alwaysKey(for permission: AgentToolPermission) -> [UInt8]? {
    switch permission.tool {
    case .shell: return Array("p".utf8)
    case .patch: return Array("a".utf8)
    default: return nil
    }
  }

  /// What "always" means for Codex, which says it in its dialog rather than in its report.
  static func alwaysAllow(for toolName: String) -> AgentAlwaysAllow? {
    switch toolName {
    case "Bash", "shell", "exec_command":
      return AgentAlwaysAllow(rules: [.commandPrefix], scope: .session)
    case "apply_patch":
      return AgentAlwaysAllow(rules: [.files], scope: .session)
    default:
      return nil
    }
  }
}

/// The mock agent reads whole lines: an answer is a word and Return.
public struct MockAnswerKeymap: AgentAnswerKeymap {
  public init() {}

  public func answers(for content: AgentRequestContent) -> Set<AgentAnswerKind> {
    switch content {
    case .permission: return [.allowOnce, .allowAlways, .deny]
    case .questions: return [.chooseOption, .writeText]
    case .unreadable: return [.deny]
    case .plan, .elicitation, .inTerminal: return []
    }
  }

  public func keystrokes(
    for answer: AgentAnswer, to content: AgentRequestContent, screen: AgentDialogScreen?
  ) -> [[UInt8]]? {
    switch (answer, content) {
    case (.allowOnce, .permission): return [Array("y\r".utf8)]
    case (.allowAlways, .permission): return [Array("a\r".utf8)]
    case (.deny, .permission), (.deny, .unreadable): return [Array("n\r".utf8)]
    case (.answers(let answers), .questions):
      return answers.map { answer in
        switch answer {
        case .option(let index): return Array("option \(index + 1)\r".utf8)
        case .options(let indices):
          let numbers = indices.sorted().map { String($0 + 1) }.joined(separator: ",")
          return Array("options \(numbers)\r".utf8)
        case .text(let text): return Array("text \(text)\r".utf8)
        }
      }
    default: return nil
    }
  }
}
