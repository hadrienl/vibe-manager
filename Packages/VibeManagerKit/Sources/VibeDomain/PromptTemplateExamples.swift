import Foundation

/// Two templates offered to start from, never installed on their own.
///
/// Their identifiers are fixed, so adding them twice adds nothing, and one the user deleted comes
/// back only if they ask for the examples again.
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
      name: "Review",
      sessionNamePattern: "Review {{url}}",
      body: """
        Review the merge request at {{url}}. Read the description and the diff, check out the \
        branch if needed, and report correctness issues first, then missing tests, then style. \
        Do not push anything.

        {{focus?}}
        """,
      fieldSettings: [
        PromptTemplateFieldSettings(name: "url", label: "Merge request URL"),
        PromptTemplateFieldSettings(
          name: "focus", label: "What to look at", help: "Optional — a part to look at closely",
          isMultiline: true),
      ],
      createdAt: date
    )
  }

  public static func feedback(createdAt date: Date) -> PromptTemplate {
    PromptTemplate(
      id: feedbackID,
      name: "Address review feedback",
      sessionNamePattern: "Feedback {{url}}",
      body: """
        Address the unresolved review comments on the merge request at {{url}}. For each one, \
        change the code or explain why not, run the tests, and summarise what you did per comment.
        """,
      fieldSettings: [
        PromptTemplateFieldSettings(name: "url", label: "Merge request URL")
      ],
      createdAt: date
    )
  }
}
