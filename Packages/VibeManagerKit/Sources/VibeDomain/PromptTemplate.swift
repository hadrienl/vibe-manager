import Foundation

public struct PromptTemplateID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public var description: String {
    rawValue.uuidString
  }
}

public enum PromptTemplateLimits {
  /// Past this, a template is no longer a form.
  public static let fieldLimit = 20
  /// The body cannot weigh more than the prompt either CLI accepts: a template whose text alone
  /// is over that could never be launched, whatever is typed in its fields.
  public static let bodyByteLimit = 16 * 1024
  /// A session name made from a template is cut here, so a pasted URL does not become a name
  /// the sidebar cannot show.
  public static let sessionNameLength = 80
}

/// What the user set about one field, beyond what the text says.
///
/// Whether a field exists, and whether it is required, is read from the text itself: these are
/// only the words and the shape of its control.
public struct PromptTemplateFieldSettings: Hashable, Codable, Sendable {
  /// The field's key, lowercased: `{{URL}}` and `{{url}}` are one field.
  public var name: String
  /// `nil`: derived from the name, "mr_url" reading "Mr url".
  public var label: String?
  /// Shown inside the empty control.
  public var help: String?
  public var isMultiline: Bool

  public init(name: String, label: String? = nil, help: String? = nil, isMultiline: Bool = false) {
    self.name = name.lowercased()
    self.label = label
    self.help = help
    self.isMultiline = isMultiline
  }
}

/// One field of a template, as the form shows it.
public struct PromptTemplateField: Hashable, Sendable, Identifiable {
  public let name: String
  public let label: String
  public let help: String?
  public let isRequired: Bool
  public let isMultiline: Bool

  public var id: String { name }

  public init(name: String, label: String, help: String?, isRequired: Bool, isMultiline: Bool) {
    self.name = name
    self.label = label
    self.help = help
    self.isRequired = isRequired
    self.isMultiline = isMultiline
  }

  /// "mr_url" → "Mr url": the name as a person would write it, until one is chosen.
  public static func derivedLabel(for spelling: String) -> String {
    let words = spelling.replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
    guard let first = words.first else { return spelling }
    return first.uppercased() + words.dropFirst()
  }
}

/// A prompt the user fills in rather than writes: `Review {{url}}`.
///
/// A starting point, never a link. A session keeps the text it was launched with and a reference
/// to the template, so editing or deleting a template changes no session.
public struct PromptTemplate: Identifiable, Hashable, Sendable {
  public let id: PromptTemplateID
  public var name: String
  /// Makes the session's name from the same fields; empty leaves the name to the user.
  public var sessionNamePattern: String
  public var body: String
  /// The folder the New Session sheet proposes with this template, as written — `~/Projects/api`
  /// stays that, so a template exported to another Mac still means the same folder there. `nil`:
  /// the sheet's folder is left as it is.
  public var workingDirectoryPath: String?
  /// Only the settings of fields present in the text are kept when the template is saved.
  public var fieldSettings: [PromptTemplateFieldSettings]
  /// One more at each save, and recorded by the sessions created from it.
  public var revision: Int
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: PromptTemplateID = PromptTemplateID(),
    name: String,
    sessionNamePattern: String = "",
    body: String,
    workingDirectoryPath: String? = nil,
    fieldSettings: [PromptTemplateFieldSettings] = [],
    revision: Int = 1,
    createdAt: Date = Date(),
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.sessionNamePattern = sessionNamePattern
    self.body = body
    self.workingDirectoryPath = workingDirectoryPath
    self.fieldSettings = fieldSettings
    self.revision = revision
    self.createdAt = createdAt.storageRounded
    self.updatedAt = (updatedAt ?? createdAt).storageRounded
  }

  public var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The fields, in the order they are first read: the session name first, then the body.
  public var fields: [PromptTemplateField] {
    let placeholders =
      PromptTemplateSyntax.parse(sessionNamePattern).placeholders
      + PromptTemplateSyntax.parse(body).placeholders
    var order: [String] = []
    var spelling: [String: String] = [:]
    var optional: Set<String> = []
    for placeholder in placeholders {
      if spelling[placeholder.key] == nil {
        order.append(placeholder.key)
        spelling[placeholder.key] = placeholder.spelling
      }
      // Marked optional once, it is optional everywhere: a field cannot be required in the name
      // and optional in the body, since both are filled from one control.
      if placeholder.isOptional {
        optional.insert(placeholder.key)
      }
    }
    return order.map { key in
      let settings = settings(for: key)
      let label = settings?.label?.trimmingCharacters(in: .whitespacesAndNewlines)
      return PromptTemplateField(
        name: key,
        label: label.flatMap { $0.isEmpty ? nil : $0 }
          ?? PromptTemplateField.derivedLabel(for: spelling[key] ?? key),
        help: settings?.help.flatMap { $0.isEmpty ? nil : $0 },
        isRequired: !optional.contains(key),
        isMultiline: settings?.isMultiline ?? false
      )
    }
  }

  public func settings(for key: String) -> PromptTemplateFieldSettings? {
    fieldSettings.first { $0.name == key.lowercased() }
  }

  /// Changes a field's settings, creating them on first use.
  public mutating func updateSettings(
    for key: String, _ change: (inout PromptTemplateFieldSettings) -> Void
  ) {
    let key = key.lowercased()
    if let index = fieldSettings.firstIndex(where: { $0.name == key }) {
      change(&fieldSettings[index])
    } else {
      var settings = PromptTemplateFieldSettings(name: key)
      change(&settings)
      fieldSettings.append(settings)
    }
  }

  /// Makes a field required or optional by writing or removing its `?` in the text, everywhere
  /// it appears: the text is where that is read, so it is also where it is changed.
  public mutating func setRequired(_ isRequired: Bool, for key: String) {
    sessionNamePattern = PromptTemplateSyntax.settingOptional(
      !isRequired, for: key, in: sessionNamePattern)
    body = PromptTemplateSyntax.settingOptional(!isRequired, for: key, in: body)
  }

  /// The settings worth keeping: those of fields still in the text.
  public var trimmedFieldSettings: [PromptTemplateFieldSettings] {
    let keys = Set(fields.map(\.name))
    return fieldSettings.filter { settings in
      keys.contains(settings.name)
        && (settings.label?.isEmpty == false || settings.help?.isEmpty == false
          || settings.isMultiline)
    }
  }

  /// Whether two templates say the same thing, whatever their history.
  public func hasSameContent(as other: PromptTemplate) -> Bool {
    name == other.name && sessionNamePattern == other.sessionNamePattern && body == other.body
      && folder == other.folder
      && Set(trimmedFieldSettings) == Set(other.trimmedFieldSettings)
  }

  /// The folder to propose, trimmed; `nil` when there is none.
  public var folder: String? {
    guard let path = workingDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
      !path.isEmpty
    else { return nil }
    return path
  }

  /// Everything that keeps this template from being saved, all at once.
  ///
  /// - Parameter others: the other templates, whose names this one must not repeat.
  public func problems(among others: [PromptTemplate]) -> [PromptTemplateIssue] {
    var issues: [PromptTemplateIssue] = []
    if trimmedName.isEmpty {
      issues.append(.nameMissing)
    } else if others.contains(where: {
      $0.id != id
        && $0.trimmedName.caseInsensitiveCompare(trimmedName) == .orderedSame
    }) {
      issues.append(.nameTaken(trimmedName))
    }
    if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(.bodyMissing)
    }
    // Only its shape: whether the folder exists is for the sheet to find out, on the Mac and at
    // the moment the session is created.
    if let folder, !(folder.hasPrefix("/") || folder == "~" || folder.hasPrefix("~/")) {
      issues.append(.folderNotAbsolute)
    }
    let byteCount = body.utf8.count
    if byteCount > PromptTemplateLimits.bodyByteLimit {
      issues.append(.bodyTooLarge(byteCount: byteCount))
    }
    let fieldCount = fields.count
    if fieldCount > PromptTemplateLimits.fieldLimit {
      issues.append(.tooManyFields(fieldCount))
    }
    for (text, field) in [
      (sessionNamePattern, PromptTemplateIssueField.sessionName), (body, .body),
    ] {
      var seen: Set<String> = []
      for placeholder in PromptTemplateSyntax.parse(text).placeholders {
        guard let pattern = placeholder.pattern, seen.insert(pattern).inserted,
          let reason = PromptTemplateExtraction(pattern: pattern).problem
        else { continue }
        issues.append(.invalidPattern(pattern, reason: reason, in: field))
      }
    }
    return issues
  }

  /// The patterns applied to a field, each once, with where they are used.
  public func extractions(for key: String) -> [PromptTemplateExtractionUse] {
    let key = key.lowercased()
    var uses: [PromptTemplateExtractionUse] = []
    for (text, place) in [
      (sessionNamePattern, PromptTemplateExtractionUse.Place.sessionName), (body, .prompt),
    ] {
      for placeholder in PromptTemplateSyntax.parse(text).placeholders
      where placeholder.key == key {
        guard let pattern = placeholder.pattern else { continue }
        if let index = uses.firstIndex(where: { $0.pattern == pattern }) {
          uses[index].places.insert(place)
        } else {
          uses.append(PromptTemplateExtractionUse(pattern: pattern, places: [place]))
        }
      }
    }
    return uses
  }
}

/// A pattern applied to a field, and where in the template.
public struct PromptTemplateExtractionUse: Hashable, Sendable, Identifiable {
  public enum Place: String, Hashable, Sendable, Comparable {
    case sessionName = "Session name"
    case prompt = "Prompt"

    public static func < (lhs: Place, rhs: Place) -> Bool {
      lhs == .sessionName && rhs == .prompt
    }
  }

  public let pattern: String
  public var places: Set<Place>

  public var id: String { pattern }

  /// "Session name, Prompt".
  public var placesLabel: String {
    places.sorted().map(\.rawValue).joined(separator: ", ")
  }
}

public enum PromptTemplateIssueField: String, Hashable, Sendable {
  case name
  case sessionName
  case body
  case folder
}

/// One reason a template cannot be saved, and the way out of it — the shape of
/// `SessionDraftIssue`, so both render the same way.
public struct PromptTemplateIssue: Hashable, Sendable, Identifiable {
  public let field: PromptTemplateIssueField
  public let message: String
  public let remedy: String

  public init(field: PromptTemplateIssueField, message: String, remedy: String) {
    self.field = field
    self.message = message
    self.remedy = remedy
  }

  public var id: String { "\(field.rawValue)|\(message)" }

  public static let nameMissing = PromptTemplateIssue(
    field: .name,
    message: "A name is required.",
    remedy: "Name the task this template is for — it is how you pick it."
  )

  public static func nameTaken(_ name: String) -> PromptTemplateIssue {
    PromptTemplateIssue(
      field: .name,
      message: "Another template is already called “\(name)”.",
      remedy: "Pick a name that tells them apart."
    )
  }

  public static let bodyMissing = PromptTemplateIssue(
    field: .body,
    message: "The prompt is empty.",
    remedy: "Write what the agent should be asked, with {{fields}} where the text changes."
  )

  public static func bodyTooLarge(byteCount: Int) -> PromptTemplateIssue {
    PromptTemplateIssue(
      field: .body,
      message:
        "The prompt weighs \(PromptSize.label(byteCount)); agents accept \(PromptSize.label(PromptTemplateLimits.bodyByteLimit)).",
      remedy: "Shorten it."
    )
  }

  public static func invalidPattern(
    _ pattern: String, reason: String, in field: PromptTemplateIssueField
  ) -> PromptTemplateIssue {
    PromptTemplateIssue(
      field: field,
      message: "/\(pattern)/ is not a valid regular expression: \(reason)",
      remedy: "Fix it, or remove the |/…/ to use the whole value."
    )
  }

  public static let folderNotAbsolute = PromptTemplateIssue(
    field: .folder,
    message: "The folder must be an absolute path.",
    remedy: "Choose it again, or type a path starting with / or ~."
  )

  public static func tooManyFields(_ count: Int) -> PromptTemplateIssue {
    PromptTemplateIssue(
      field: .body,
      message:
        "This template has \(count) fields; a template may have \(PromptTemplateLimits.fieldLimit).",
      remedy: "Merge some of them, or write the parts that never change as text."
    )
  }
}

/// "1.2 KB", counted in powers of two like the limits it is compared with.
public enum PromptSize {
  public static func label(_ byteCount: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .memory)
  }
}
