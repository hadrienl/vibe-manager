import Foundation
import VibeApplication

/// Claude Code's dialogs, as drawn by 2.1.282 (#40).
///
/// - A permission: `1. Yes` / `2. Yes, and always allow…` — only when the request carries
///   `permission_suggestions` — / `3. No`. Escape refuses whatever the options are: a digit for
///   "No" guessed one place off would allow instead.
/// - Questions: a digit picks its option and moves on; the one after the options is "Type
///   something.", which takes pasted text and Return. A question of several choices is a list of
///   boxes, as drawn by 2.1.283: a digit ticks its option and stays, the right arrow moves on.
///   Several questions, or one of several choices, end on a review, whose `1` submits.
/// - A plan: `1` accepts it with edits accepted, `2` with each edit asking first; Escape rejects.
///
/// Return is never pressed to pick an option: it takes the highlighted one, whatever that is.
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
    case .elicitation:
      return []
    }
  }

  public func keystrokes(for answer: AgentAnswer, to content: AgentRequestContent) -> [[UInt8]]? {
    switch (answer, content) {
    case (.allowOnce, .permission):
      return [Array("1".utf8)]
    case (.allowAlways, .permission(let permission)) where permission.alwaysAllow != nil:
      return [Array("2".utf8)]
    case (.deny, .permission), (.deny, .unreadable), (.rejectPlan, .plan):
      return [TerminalKeys.escape]
    case (.approvePlan(let approval), .plan):
      return [Array((approval == .acceptEdits ? "1" : "2").utf8)]
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
      guard question.options.indices.contains(index) else { return nil }
      return TerminalKeys.digit(forOption: index).map { [$0] }
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

/// Codex's approval dialogs, as drawn by 0.157.1 (#40): `y` runs it once, `p` stops asking for
/// commands that start the same way, `a` for the files of a patch; Escape refuses. Its questions
/// are reported before they are drawn, and are answered in the terminal.
public struct CodexAnswerKeymap: AgentAnswerKeymap {
  public init() {}

  public func answers(for content: AgentRequestContent) -> Set<AgentAnswerKind> {
    switch content {
    case .permission(let permission):
      return Self.alwaysKey(for: permission) == nil
        ? [.allowOnce, .deny] : [.allowOnce, .allowAlways, .deny]
    case .unreadable:
      return [.deny]
    case .questions, .plan, .elicitation:
      return []
    }
  }

  public func keystrokes(for answer: AgentAnswer, to content: AgentRequestContent) -> [[UInt8]]? {
    switch (answer, content) {
    case (.allowOnce, .permission):
      return [Array("y".utf8)]
    case (.allowAlways, .permission(let permission)):
      return Self.alwaysKey(for: permission).map { [$0] }
    case (.deny, .permission), (.deny, .unreadable):
      return [TerminalKeys.escape]
    default:
      return nil
    }
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
    case .plan, .elicitation: return []
    }
  }

  public func keystrokes(for answer: AgentAnswer, to content: AgentRequestContent) -> [[UInt8]]? {
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
