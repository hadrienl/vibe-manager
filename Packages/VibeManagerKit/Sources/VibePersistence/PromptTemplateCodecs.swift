import Foundation
import VibeApplication
import VibeDomain

enum PromptTemplateCodecError: Error, Equatable {
  case invalid
  case unsupportedVersion(Int)
}

/// `templates.json`: the store, versioned, with DTOs of its own so that a change of the domain
/// is never an accidental change of the file. The order of the array is the order shown.
struct PromptTemplateStoreCodec {
  static let currentSchemaVersion = 1

  func encode(_ library: PromptTemplateLibrary) throws -> Data {
    let document = StoredTemplatesV1(
      schemaVersion: Self.currentSchemaVersion,
      templates: library.templates.map(StoredTemplateV1.init))
    return try SessionStoreCodec.makeEncoder().encode(document)
  }

  func decode(_ data: Data) throws -> PromptTemplateLibrary {
    let decoder = SessionStoreCodec.makeDecoder()
    guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
      throw PromptTemplateCodecError.invalid
    }
    guard probe.schemaVersion == Self.currentSchemaVersion else {
      throw PromptTemplateCodecError.unsupportedVersion(probe.schemaVersion)
    }
    guard let document = try? decoder.decode(StoredTemplatesV1.self, from: data) else {
      throw PromptTemplateCodecError.invalid
    }
    return PromptTemplateLibrary(templates: document.templates.map(\.domainValue))
  }
}

private struct VersionProbe: Decodable {
  let schemaVersion: Int
}

private struct StoredTemplatesV1: Codable {
  let schemaVersion: Int
  let templates: [StoredTemplateV1]
}

private struct StoredTemplateV1: Codable {
  let id: UUID
  let name: String
  let sessionNamePattern: String
  let body: String
  let fields: [StoredFieldSettingsV1]
  let revision: Int
  let createdAt: Date
  let updatedAt: Date

  init(_ template: PromptTemplate) {
    id = template.id.rawValue
    name = template.name
    sessionNamePattern = template.sessionNamePattern
    body = template.body
    fields = template.fieldSettings.map(StoredFieldSettingsV1.init)
    revision = template.revision
    createdAt = template.createdAt
    updatedAt = template.updatedAt
  }

  var domainValue: PromptTemplate {
    PromptTemplate(
      id: PromptTemplateID(rawValue: id),
      name: name,
      sessionNamePattern: sessionNamePattern,
      body: body,
      fieldSettings: fields.map(\.domainValue),
      revision: revision,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

private struct StoredFieldSettingsV1: Codable {
  let name: String
  let label: String?
  let help: String?
  let multiline: Bool

  init(_ settings: PromptTemplateFieldSettings) {
    name = settings.name
    label = settings.label
    help = settings.help
    multiline = settings.isMultiline
  }

  var domainValue: PromptTemplateFieldSettings {
    PromptTemplateFieldSettings(name: name, label: label, help: help, isMultiline: multiline)
  }
}

// MARK: - Exchange

public enum PromptTemplateExchangeError: Error, Equatable, Sendable, LocalizedError {
  case tooLarge(byteCount: Int)
  case notATemplateFile
  case unsupportedVersion(Int)

  public var errorDescription: String? {
    switch self {
    case .tooLarge(let byteCount):
      return
        "This file weighs \(PromptSize.label(byteCount)); a template file is at most \(PromptSize.label(PromptTemplateExchangeCodec.byteLimit))."
    case .notATemplateFile:
      return "This file does not hold Vibe Manager prompt templates."
    case .unsupportedVersion(let version):
      return
        "These templates were exported by a newer version of Vibe Manager (format \(version)). Update Vibe Manager to import them."
    }
  }
}

/// The file templates are exported to and imported from, documented in
/// `docs/prompt-templates.md`.
///
/// Distinct from the store on purpose: the store may change shape between versions, a file
/// someone was sent must not. It carries no revision and no dates: a file has no history to
/// impose on the library it lands in.
public struct PromptTemplateExchangeCodec: PromptTemplateExchangeFormat {
  public static let format = "vibe-manager.prompt-templates"
  public static let currentVersion = 1
  public static let byteLimit = 1024 * 1024

  public init() {}

  public func encode(_ templates: [PromptTemplate], exportedAt date: Date) throws -> Data {
    let document = ExchangeDocumentV1(
      format: Self.format,
      version: Self.currentVersion,
      exportedAt: date,
      templates: templates.map(ExchangeTemplateV1.init))
    return try SessionStoreCodec.makeEncoder().encode(document)
  }

  /// The templates of a file, each with the identifier it was exported with; the dates are the
  /// import's own. A file of a format or a version this build does not know is refused whole.
  public func decode(_ data: Data, importedAt date: Date) throws -> [PromptTemplate] {
    guard data.count <= Self.byteLimit else {
      throw PromptTemplateExchangeError.tooLarge(byteCount: data.count)
    }
    let decoder = SessionStoreCodec.makeDecoder()
    guard let probe = try? decoder.decode(ExchangeProbe.self, from: data),
      probe.format == Self.format
    else {
      throw PromptTemplateExchangeError.notATemplateFile
    }
    guard probe.version <= Self.currentVersion, probe.version >= 1 else {
      throw PromptTemplateExchangeError.unsupportedVersion(probe.version)
    }
    guard let document = try? decoder.decode(ExchangeDocumentV1.self, from: data) else {
      throw PromptTemplateExchangeError.notATemplateFile
    }
    return document.templates.map { $0.domainValue(at: date) }
  }
}

private struct ExchangeProbe: Decodable {
  let format: String
  let version: Int
}

private struct ExchangeDocumentV1: Codable {
  let format: String
  let version: Int
  let exportedAt: Date?
  let templates: [ExchangeTemplateV1]
}

private struct ExchangeTemplateV1: Codable {
  let id: UUID
  let name: String
  let sessionName: String?
  let body: String
  let fields: [ExchangeFieldV1]?

  init(_ template: PromptTemplate) {
    id = template.id.rawValue
    name = template.name
    sessionName = template.sessionNamePattern
    body = template.body
    fields = template.trimmedFieldSettings.map(ExchangeFieldV1.init)
  }

  func domainValue(at date: Date) -> PromptTemplate {
    PromptTemplate(
      id: PromptTemplateID(rawValue: id),
      name: name,
      sessionNamePattern: sessionName ?? "",
      body: body,
      fieldSettings: (fields ?? []).map(\.domainValue),
      revision: 1,
      createdAt: date
    )
  }
}

private struct ExchangeFieldV1: Codable {
  let name: String
  let label: String?
  let help: String?
  let multiline: Bool?

  init(_ settings: PromptTemplateFieldSettings) {
    name = settings.name
    label = settings.label
    help = settings.help
    multiline = settings.isMultiline
  }

  var domainValue: PromptTemplateFieldSettings {
    PromptTemplateFieldSettings(
      name: name, label: label, help: help, isMultiline: multiline ?? false)
  }
}
