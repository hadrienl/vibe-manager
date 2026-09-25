import Foundation
import VibeDomain

public enum PromptTemplateStoreError: Error, Equatable, Sendable, LocalizedError {
  /// The file is there but could not be read, or was written by a newer version. It is never
  /// written over: its bytes are the only copy of the user's templates.
  case unreadable(reason: String)
  case cannotWrite(reason: String)

  public var errorDescription: String? {
    switch self {
    case .unreadable(let reason):
      return String(localized: "Templates couldn't be read: \(reason)", bundle: .module)
    case .cannotWrite(let reason):
      return String(localized: "Templates couldn't be saved: \(reason)", bundle: .module)
    }
  }
}

/// Where the prompt templates are kept, apart from the sessions: editing a template must not
/// rewrite the session store.
public protocol PromptTemplateRepository: Sendable {
  func library() async throws -> PromptTemplateLibrary
  /// Applies `change` to the stored library and writes it, as one step: two changes never read
  /// the same library and lose one another.
  @discardableResult
  func update<Result: Sendable>(
    _ change: @Sendable (inout PromptTemplateLibrary) throws -> Result
  ) async throws -> (PromptTemplateLibrary, Result)
  /// Where the file is, for Reveal in Finder when it cannot be read. `nil`: nowhere on disk.
  var fileURL: URL? { get }
}

/// Templates held in memory, for tests and for a workspace assembled without a store.
public actor InMemoryPromptTemplateRepository: PromptTemplateRepository {
  private var stored: PromptTemplateLibrary

  public init(templates: [PromptTemplate] = []) {
    stored = PromptTemplateLibrary(templates: templates)
  }

  public func library() -> PromptTemplateLibrary {
    stored
  }

  @discardableResult
  public func update<Result: Sendable>(
    _ change: @Sendable (inout PromptTemplateLibrary) throws -> Result
  ) throws -> (PromptTemplateLibrary, Result) {
    var copy = stored
    let result = try change(&copy)
    stored = copy
    return (copy, result)
  }

  public nonisolated var fileURL: URL? { nil }
}

/// The file templates travel in between two libraries, documented in `docs/prompt-templates.md`.
public protocol PromptTemplateExchangeFormat: Sendable {
  func encode(_ templates: [PromptTemplate], exportedAt date: Date) throws -> Data
  /// The templates of a file; a file this build cannot fully understand is refused whole.
  func decode(_ data: Data, importedAt date: Date) throws -> [PromptTemplate]
}
