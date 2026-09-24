import Foundation

/// What a prompt may contain on its way to an agent.
///
/// The prompt travels in `argv`, with no shell in between, so nothing needs quoting — and quoting
/// would show in the prompt. What does matter is what a terminal program would act on: a NUL cuts
/// the argument short, and an escape sequence pasted from coloured output would drive the CLI's
/// display. Tabs and newlines are text; every other control character is not.
public enum PromptText {
  /// Whether `scalar` is a control character a prompt must not carry.
  public static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09, 0x0A: return false
    case 0x00...0x1F, 0x7F: return true
    default: return false
    }
  }

  public static func containsForbiddenCharacters(_ text: String) -> Bool {
    text.unicodeScalars.contains(where: isForbidden)
  }

  /// Line breaks as `\n`: `\r\n` and `\r` pasted from elsewhere are line breaks, not control
  /// characters to refuse.
  public static func normalizingLineBreaks(_ text: String) -> String {
    guard text.unicodeScalars.contains("\r") else { return text }
    return text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
  }

  /// Line breaks as `\n`, and without the control characters a prompt must not carry.
  public static func sanitized(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    var previousWasCarriageReturn = false
    for scalar in text.unicodeScalars {
      if scalar == "\r" {
        scalars.append("\n")
        previousWasCarriageReturn = true
        continue
      }
      defer { previousWasCarriageReturn = false }
      if scalar == "\n", previousWasCarriageReturn { continue }
      if isForbidden(scalar) { continue }
      scalars.append(scalar)
    }
    return String(scalars)
  }

  /// A value typed in a field, as it goes into the prompt.
  ///
  /// A one-line field stays on one line — a URL pasted with its line break must not break the
  /// sentence around it — and loses its surrounding spaces. A multiline field only loses what
  /// trails it.
  public static func fieldValue(_ value: String, isMultiline: Bool) -> String {
    let clean = sanitized(value)
    if isMultiline {
      var result = clean
      while let last = result.unicodeScalars.last,
        CharacterSet.whitespacesAndNewlines.contains(last)
      {
        result.unicodeScalars.removeLast()
      }
      return result
    }
    return clean.replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// A template and what the user typed in its fields: everything the preview and the launch read.
///
/// One rendering, used by both, so the preview cannot say something the agent is not sent.
public struct PromptTemplateFill: Hashable, Sendable {
  /// A copy taken when the template was picked: saving the template elsewhere meanwhile does not
  /// change what is being previewed.
  public var template: PromptTemplate
  /// By field key.
  public var values: [String: String]

  public init(template: PromptTemplate, values: [String: String] = [:]) {
    self.template = template
    self.values = values
  }

  public func value(for key: String) -> String {
    values[key.lowercased()] ?? ""
  }

  public mutating func setValue(_ value: String, for key: String) {
    values[key.lowercased()] = value
  }

  /// The fields that must be filled and are not. A value made of spaces is not a value.
  public var missingRequiredFields: [PromptTemplateField] {
    template.fields.filter { field in
      field.isRequired
        && PromptText.fieldValue(value(for: field.name), isMultiline: true)
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  public func render() -> RenderedPrompt {
    let fields = Dictionary(
      template.fields.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    var parts: [RenderedPrompt.Part] = []
    for segment in PromptTemplateSyntax.parse(template.body).segments {
      switch segment {
      case .text(let text):
        parts.append(.text(PromptText.sanitized(text)))
      case .placeholder(let placeholder):
        let field = fields[placeholder.key]
        let filled = PromptText.fieldValue(
          value(for: placeholder.key), isMultiline: field?.isMultiline ?? false)
        if filled.isEmpty {
          parts.append(
            .missing(
              key: placeholder.key,
              label: field?.label ?? placeholder.spelling,
              spelling: placeholder.spelling,
              isRequired: field?.isRequired ?? !placeholder.isOptional))
        } else {
          // Inserted as it is, and never read again: a value holding `{{x}}` stays that text.
          parts.append(.value(key: placeholder.key, text: filled))
        }
      }
    }
    return RenderedPrompt(parts: trimmingTrailingWhitespace(parts), sessionName: sessionName())
  }

  /// The session's name, on one line and at most `PromptTemplateLimits.sessionNameLength`
  /// characters; `nil` when the template does not make one.
  public func sessionName() -> String? {
    let pattern = template.sessionNamePattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pattern.isEmpty else { return nil }
    var name = ""
    for segment in PromptTemplateSyntax.parse(pattern).segments {
      switch segment {
      case .text(let text):
        name += text
      case .placeholder(let placeholder):
        name += PromptText.fieldValue(value(for: placeholder.key), isMultiline: false)
      }
    }
    let words = PromptText.sanitized(name)
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return String(words.prefix(PromptTemplateLimits.sessionNameLength))
  }

  /// The reference a session created from this fill keeps.
  public var reference: PromptTemplateReference {
    PromptTemplateReference(
      id: template.id.description, name: template.trimmedName, revision: "\(template.revision)")
  }

  /// An optional field left empty at the end of the text would leave a dangling blank line.
  private func trimmingTrailingWhitespace(_ parts: [RenderedPrompt.Part]) -> [RenderedPrompt.Part] {
    var parts = parts
    while let last = parts.last {
      switch last {
      case .missing(_, _, _, isRequired: false):
        parts.removeLast()
      case .text(let text):
        var trimmed = text
        while let scalar = trimmed.unicodeScalars.last,
          CharacterSet.whitespacesAndNewlines.contains(scalar)
        {
          trimmed.unicodeScalars.removeLast()
        }
        parts.removeLast()
        if !trimmed.isEmpty {
          parts.append(.text(trimmed))
          return parts
        }
      default:
        return parts
      }
    }
    return parts
  }
}

/// A template filled in: the prompt the agent will be sent, and its parts for a preview.
public struct RenderedPrompt: Hashable, Sendable {
  public enum Part: Hashable, Sendable {
    case text(String)
    case value(key: String, text: String)
    /// A field left empty. An optional one adds nothing to the prompt; a required one keeps
    /// the session from being created, and is written back as `{{name}}` when the prompt is
    /// turned into free text.
    case missing(key: String, label: String, spelling: String, isRequired: Bool)
  }

  public let parts: [Part]
  public let sessionName: String?

  /// Exactly what is launched.
  public var prompt: String {
    parts.map { part in
      switch part {
      case .text(let text), .value(_, let text): return text
      case .missing: return ""
      }
    }.joined()
  }

  /// The prompt as free text: the required fields still empty stay `{{name}}`, to be filled by
  /// hand.
  public var editableText: String {
    parts.map { part in
      switch part {
      case .text(let text), .value(_, let text): return text
      case .missing(_, _, let spelling, let isRequired):
        return isRequired ? "{{\(spelling)}}" : ""
      }
    }.joined()
  }

  public var byteCount: Int {
    prompt.utf8.count
  }
}
