import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

/// Several questions as Claude Code 2.1.300 draws them, one tab each, then a review.
enum SeveralQuestionsScreens {
  static func tabs(_ boxes: String) -> String {
    "────────────────────────────────────────\n←  \(boxes)  ✔ Submit  →\n"
  }

  static let colour =
    tabs("☐ Color  ☐ Pets  ☐ Size") + """

      Pick a color?

      ❯ 1. Red
           Couleur rouge
        2. Blue
           Couleur bleue
        3. Type something.
      ────────────────────────────────────────
        4. Chat about this

      Enter to select · Tab/Arrow keys to navigate · Esc to cancel
      """

  static func pets(_ boxes: String, cat: String = " ") -> String {
    tabs(boxes) + """

      Which pets?

      ❯ 1. [\(cat)] Cat
               Un chat
        2. [ ] Dog
               Un chien
        3. [ ] Type something
           Next
      ────────────────────────────────────────
        4. Chat about this

      Enter to select · Tab/Arrow keys to navigate · Esc to cancel
      """
  }

  static let size =
    tabs("☒ Color  ☒ Pets  ☐ Size") + """

      Pick a size?

      ❯ 1. Small
           Taille petite
        2. Large
           Taille grande
        3. Type something.
      ────────────────────────────────────────
        4. Chat about this

      Enter to select · Tab/Arrow keys to navigate · Esc to cancel
      """

  static let review =
    tabs("☒ Color  ☒ Pets  ☒ Size") + """

      Review your answers

       ● Pick a color?
         → Blue
       ● Which pets?
         → Cat, Dog
       ● Pick a size?
         → Small

      Ready to submit your answers?

      ❯ 1. Submit answers
        2. Cancel
      """
}

@Suite("Several questions are answered one drawn question at a time")
struct SeveralQuestionsTests {
  let keymap = ClaudeCodeAnswerKeymap()
  let questions = AgentRequestContent.questions([
    AgentQuestion(
      header: "Color", text: "Pick a color?", options: [.init(label: "Red"), .init(label: "Blue")]),
    AgentQuestion(
      header: "Pets", text: "Which pets?", options: [.init(label: "Cat"), .init(label: "Dog")],
      allowsMultipleChoices: true),
    AgentQuestion(
      header: "Size", text: "Pick a size?", options: [.init(label: "Small"), .init(label: "Large")]),
  ])
  let answer = AgentAnswer.answers([.option(1), .options([0, 1]), .option(0)])
  let two = Array("2".utf8)
  let one = Array("1".utf8)

  func screen(_ text: String) -> AgentDialogScreen? {
    AgentDialogScreen(screen: text)
  }

  @Test("The tabs above the questions say which have an answer")
  func tabs() {
    typealias Screens = SeveralQuestionsScreens
    #expect(screen(Screens.colour)?.questionTabs == [false, false, false])
    #expect(screen(Screens.pets("☒ Color  ☐ Pets  ☐ Size"))?.questionTabs == [true, false, false])
    #expect(screen(Screens.review)?.questionTabs == [true, true, true])
    #expect(screen(DialogScreens.claudeBash)?.questionTabs == nil)
  }

  @Test("Tabs shortened by a narrow terminal still say which have an answer")
  func narrowTabs() {
    // Captured from 2.1.300 at 60, then 40 columns.
    let options = "\n\nWhich branch?\n\n❯ 1. Main\n  2. Release\n  3. Type something."
    let sixty = "←  ☒ Prere…  ☐ Hotfixbranch  ☐ Relea…  ☐ Deplo…  ✔ Submit  →" + options
    let forty = "←  ☒ P… ☐ Hotfixbr… ☐ R… ☐ D… ✔ Submit →" + options
    #expect(screen(sixty)?.questionTabs == [true, false, false, false])
    #expect(screen(forty)?.questionTabs == [true, false, false, false])
  }

  @Test("The first key of each question, and the review's, waits for it to be drawn")
  func checkpoints() {
    let all = keymap.keystrokes(
      for: answer, to: questions, screen: screen(SeveralQuestionsScreens.colour))
    #expect(all == [two, one, two, TerminalKeys.rightArrow, one, one])
    let rereads = (1..<6).filter {
      keymap.rereadsScreen(beforeStep: $0, of: answer, to: questions)
    }
    #expect(rereads == [1, 4, 5])
  }

  @Test("The keys left run from the question drawn, or from the review")
  func keysLeft() {
    typealias Screens = SeveralQuestionsScreens
    func left(_ text: String) -> [[UInt8]]? {
      keymap.keystrokesLeft(for: answer, to: questions, screen: screen(text))
    }
    #expect(left(Screens.pets("☒ Color  ☐ Pets  ☐ Size")) == [one, two, TerminalKeys.rightArrow, one, one])
    #expect(left(Screens.size) == [one, one])
    #expect(left(Screens.review) == [one])
    // The first question still drawn: the key typed for it has not been read yet.
    #expect(left(Screens.colour) == [two, one, two, TerminalKeys.rightArrow, one, one])
  }

  @Test("A box ticked by someone else, or tabs out of order, leave nothing to type")
  func touched() {
    typealias Screens = SeveralQuestionsScreens
    func left(_ text: String) -> [[UInt8]]? {
      keymap.keystrokesLeft(for: answer, to: questions, screen: screen(text))
    }
    #expect(left(Screens.pets("☒ Color  ☒ Pets  ☐ Size", cat: "✔")) == nil)
    #expect(left(Screens.pets("☐ Color  ☐ Pets  ☒ Size")) == nil)
    #expect(left(DialogScreens.claudeBash) == nil)
    // A box of the first question ticked in the terminal: its digit would untick it.
    let ticked = AgentRequestContent.questions([
      AgentQuestion(
        header: "Pets", text: "Which pets?", options: [.init(label: "Cat"), .init(label: "Dog")],
        allowsMultipleChoices: true),
      AgentQuestion(
        header: "Size", text: "Pick a size?", options: [.init(label: "Small"), .init(label: "Large")]),
    ])
    let both = AgentAnswer.answers([.options([0, 1]), .option(0)])
    let drawn = { (cat: String) in
      screen(SeveralQuestionsScreens.pets("☐ Pets  ☐ Size", cat: cat))
    }
    #expect(keymap.keystrokes(for: both, to: ticked, screen: drawn(" ")) != nil)
    #expect(keymap.keystrokes(for: both, to: ticked, screen: drawn("✔")) == nil)
  }

  @Test("Two questions with the same options are told apart by their tabs")
  func sameOptions() {
    let yesNo = { (text: String) in
      AgentQuestion(
        header: text, text: text, options: [.init(label: "Yes"), .init(label: "No")])
    }
    let both = AgentRequestContent.questions([yesNo("First?"), yesNo("Second?")])
    let drawn = { (boxes: String) in
      SeveralQuestionsScreens.tabs(boxes) + """

        Second?

        ❯ 1. Yes
          2. No
          3. Type something.
        """
    }
    let answer = AgentAnswer.answers([.option(0), .option(1)])
    #expect(
      keymap.keystrokesLeft(for: answer, to: both, screen: screen(drawn("☐ A  ☐ B")))
        == [one, two, one])
    #expect(
      keymap.keystrokesLeft(for: answer, to: both, screen: screen(drawn("☒ A  ☐ B"))) == [two, one])
  }

  @Test("One question of several choices is submitted once its review is drawn")
  func singleMultipleChoice() {
    let pets = AgentRequestContent.questions([
      AgentQuestion(
        header: "Pets", text: "Which pets?", options: [.init(label: "Cat"), .init(label: "Dog")],
        allowsMultipleChoices: true)
    ])
    let answer = AgentAnswer.answers([.options([0])])
    // As drawn by 2.1.300; 2.1.288 drew its tabs after `⏺`.
    let review =
      SeveralQuestionsScreens.tabs("☒ Pets") + """

        Review your answers

         ● Which pets?
           → Cat

        Ready to submit your answers?

        ❯ 1. Submit answers
          2. Cancel
        """
    #expect(keymap.rereadsScreen(beforeStep: 2, of: answer, to: pets))
    #expect(keymap.keystrokesLeft(for: answer, to: pets, screen: screen(review)) == [one])
    #expect(screen(QuestionScreens.multiple)?.questionTabs == [false])
  }

  @Test("A first question answered in the terminal is not answered again into the next")
  func firstAnsweredInTerminal() {
    let yesNo = { (text: String) in
      AgentQuestion(header: text, text: text, options: [.init(label: "Yes"), .init(label: "No")])
    }
    let both = AgentRequestContent.questions([yesNo("First?"), yesNo("Second?")])
    let drawn = { (boxes: String) in
      SeveralQuestionsScreens.tabs(boxes) + """

        Second?

        ❯ 1. Yes
          2. No
          3. Type something.
        """
    }
    let answer = AgentAnswer.answers([.option(0), .option(1)])
    #expect(keymap.keystrokes(for: answer, to: both, screen: screen(drawn("☒ A  ☐ B"))) == nil)
    #expect(keymap.keystrokes(for: answer, to: both, screen: screen(drawn("☐ A  ☐ B"))) != nil)
  }
}
