import Foundation

/// Two templates offered to start from, never installed on their own.
///
/// Both name the session after the number in the merge request's URL — GitLab's
/// `merge_requests/1315` or GitHub's `pull/64` — which is what a review is usually called.
///
/// Their identifiers are fixed, so adding them twice adds nothing, and one the user deleted comes
/// back only if they ask for the examples again.
///
/// Written in the language the application runs in when they are added: from then on they are the
/// user's templates, and stay as they were whatever the language becomes.
public enum PromptTemplateExamples {
  public static let reviewID = PromptTemplateID(
    rawValue: UUID(uuidString: "6F1C2A4E-7D35-4B8A-9E61-2C0D5B7A1E01")!)
  public static let feedbackID = PromptTemplateID(
    rawValue: UUID(uuidString: "6F1C2A4E-7D35-4B8A-9E61-2C0D5B7A1E02")!)

  public static var identifiers: [PromptTemplateID] {
    [reviewID, feedbackID]
  }

  public static func all(createdAt date: Date) -> [PromptTemplate] {
    [review(createdAt: date), feedback(createdAt: date)]
  }

  public static func review(createdAt date: Date) -> PromptTemplate {
    PromptTemplate(
      id: reviewID,
      name: reviewPrefix,
      sessionNamePattern: #"\#(reviewPrefix) {{url|/(?:merge_requests|pull)\/(\d+)/}}"#,
      body: String(
        localized: """
          Review the merge request at {{url}}. Read the description and the diff, check out the \
          branch if needed, and report correctness issues first, then missing tests, then style. \
          Do not push anything.

          {{focus?}}
          """,
        bundle: .module,
        comment: "The prompt of an example template. Keep {{url}} and {{focus?}} as they are."),
      appearance: SessionAppearance(symbolName: "doc.text", colorHex: "#0B63E5"),
      fieldSettings: [
        PromptTemplateFieldSettings(name: "url", label: mergeRequestURL),
        PromptTemplateFieldSettings(
          name: "focus",
          label: String(
            localized: "What to look at", bundle: .module,
            comment: "A field of the example review template."),
          help: String(
            localized: "Optional — a part to look at closely", bundle: .module,
            comment: "The help of a field of the example review template."),
          isMultiline: true),
      ],
      createdAt: date
    )
  }

  public static func feedback(createdAt date: Date) -> PromptTemplate {
    PromptTemplate(
      id: feedbackID,
      name: String(
        localized: "Address review feedback", bundle: .module,
        comment: "An example prompt template."),
      sessionNamePattern: #"\#(feedbackPrefix) {{url|/(?:merge_requests|pull)\/(\d+)/}}"#,
      body: String(
        localized: """
          Address the unresolved review comments on the merge request at {{url}}. For each one, \
          change the code or explain why not, run the tests, and summarise what you did per comment.
          """,
        bundle: .module,
        comment: "The prompt of an example template. Keep {{url}} as it is."),
      appearance: SessionAppearance(symbolName: "wrench.and.screwdriver", colorHex: "#1E7F4D"),
      fieldSettings: [
        PromptTemplateFieldSettings(name: "url", label: mergeRequestURL)
      ],
      createdAt: date
    )
  }

  /// The words before the merge request's number, in the name of the sessions they start.
  private static var reviewPrefix: String {
    String(
      localized: "Review", bundle: .module,
      comment: "An example prompt template, and the start of the name of the sessions it starts.")
  }

  private static var feedbackPrefix: String {
    String(
      localized: "Feedback", bundle: .module,
      comment:
        "The start of the name of the sessions the example template for review feedback starts.")
  }

  private static var mergeRequestURL: String {
    String(
      localized: "Merge request URL", bundle: .module,
      comment: "A field of the example templates: the link to a merge or pull request.")
  }
}
