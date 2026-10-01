import Foundation
import Testing

/// A prompt template and a model of an agent never share a word (#221): in French, « modèle » is
/// the model alone, and a template is a « gabarit » (docs/localization.md). The English keys tell
/// them apart already — `template` in one, `model` in the other — so the rule is read from them,
/// with no list of strings to keep up to date.
@Suite("A template never takes the word of a model")
struct TemplateWordingTests {
  /// The word each language gives a model of an agent, as a pattern that matches its inflections.
  /// A language added to the catalogs (#215) adds its word here.
  static let modelWords: [String: String] = ["fr": #"mod[eè]le"#]

  /// What is wrong with a translation, or nil: a template named with the word of a model, or that
  /// word used for something that is not a model.
  static func problem(key: String, value: String, modelWord: String) -> String? {
    let saysModel =
      value.range(of: modelWord, options: [.regularExpression, .caseInsensitive]) != nil
    guard saysModel else { return nil }
    if key.range(of: "template", options: .caseInsensitive) != nil {
      return "a template named with the word of a model"
    }
    if key.range(of: "model", options: .caseInsensitive) == nil {
      return "the word of a model used for something else"
    }
    return nil
  }

  @Test("The rule tells a template from a model")
  func rule() {
    let french = Self.modelWords["fr"]!
    #expect(Self.problem(key: "Templates", value: "Modèles", modelWord: french) != nil)
    #expect(
      Self.problem(
        key: "%lld templates imported.", value: "%lld modèles importés.", modelWord: french) != nil)
    #expect(Self.problem(key: "Manage…", value: "Gérer les modeles…", modelWord: french) != nil)
    #expect(Self.problem(key: "Model", value: "Modèle", modelWord: french) == nil)
    #expect(
      Self.problem(
        key: "Default model of the agent", value: "Modèle par défaut de l’agent", modelWord: french)
        == nil)
    #expect(
      Self.problem(key: "Untitled Template", value: "Gabarit sans titre", modelWord: french) == nil)
  }

  @Test("No translation gives a template the word of a model, nor that word to anything else")
  func catalogs() throws {
    for catalog in FrenchTypographyTests.catalogs() {
      let name = catalog.deletingLastPathComponent().lastPathComponent
      for (language, word) in Self.modelWords {
        for (key, value) in try FrenchTypographyTests.values(of: catalog, language: language) {
          if let problem = Self.problem(key: key, value: value, modelWord: word) {
            Issue.record("\(name) [\(language)]: “\(key)” → “\(value)”: \(problem)")
          }
        }
      }
    }
  }
}
