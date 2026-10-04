import Foundation
import Testing

/// A prompt template and a model of an agent never share a word (#221): in French, « modèle » is
/// the model alone, and a template is a « gabarit » (docs/localization.md). The English text tells
/// them apart already — `template` in one, `model` in the other — so the rule is read from it, with
/// no list of strings to keep up to date. The English text is the key with the English value,
/// since a key of `InfoPlist.xcstrings` is an identifier (`NSLocalNetworkUsageDescription`).
@Suite("A template never takes the word of a model")
struct TemplateWordingTests {
  /// The word each language gives a model of an agent, as a pattern that matches its inflections.
  /// A language added to the catalogs adds its word here.
  static let modelWords: [String: String] = [
    "ar": #"نموذج|نماذج"#,
    "de": #"modell"#,
    "es": #"\bmodelos?\b"#,
    "fr": #"mod[eè]le"#,
    "hi": #"मॉडल"#,
    "it": #"modell[oi]"#,
    "ja": #"モデル"#,
    "ko": #"모델"#,
    "nl": #"model"#,
    "pl": #"\bmodel"#,
    "pt-BR": #"\bmodelos?\b"#,
    "ru": #"модел"#,
    "tr": #"model"#,
    "uk": #"модел"#,
    "zh-Hans": #"模型"#,
    "zh-Hant": #"模型"#,
  ]

  /// What is wrong with a translation, or nil: a template named with the word of a model, or that
  /// word used for something that is not a model.
  static func problem(english: String, value: String, modelWord: String) -> String? {
    let saysModel =
      value.range(of: modelWord, options: [.regularExpression, .caseInsensitive]) != nil
    guard saysModel else { return nil }
    if english.range(of: "template", options: .caseInsensitive) != nil {
      return "a template named with the word of a model"
    }
    if english.range(of: "model", options: .caseInsensitive) == nil {
      return "the word of a model used for something else"
    }
    return nil
  }

  @Test("The rule tells a template from a model")
  func rule() {
    let french = Self.modelWords["fr"]!
    #expect(Self.problem(english: "Templates", value: "Modèles", modelWord: french) != nil)
    #expect(
      Self.problem(
        english: "%lld templates imported.", value: "%lld modèles importés.", modelWord: french)
        != nil)
    #expect(Self.problem(english: "Manage…", value: "Gérer les modeles…", modelWord: french) != nil)
    #expect(Self.problem(english: "Model", value: "Modèle", modelWord: french) == nil)
    #expect(
      Self.problem(
        english: "NSLocalNetworkUsageDescription Vibe Manager reaches the model servers…",
        value: "Vibe Manager joint les serveurs de modèles…", modelWord: french) == nil)
    #expect(
      Self.problem(
        english: "Default model of the agent", value: "Modèle par défaut de l’agent",
        modelWord: french)
        == nil)
    #expect(
      Self.problem(english: "Untitled Template", value: "Gabarit sans titre", modelWord: french)
        == nil)
  }

  @Test("No translation gives a template the word of a model, nor that word to anything else")
  func catalogs() throws {
    for catalog in FrenchTypographyTests.catalogs() {
      let name = catalog.deletingLastPathComponent().lastPathComponent
      var english: [String: String] = [:]
      for (key, value) in try FrenchTypographyTests.values(of: catalog, language: "en") {
        english[key, default: key] += " " + value
      }
      for (language, word) in Self.modelWords {
        for (key, value) in try FrenchTypographyTests.values(of: catalog, language: language) {
          let text = english[key] ?? key
          if let problem = Self.problem(english: text, value: value, modelWord: word) {
            Issue.record("\(name) [\(language)]: “\(key)” → “\(value)”: \(problem)")
          }
        }
      }
    }
  }
}
