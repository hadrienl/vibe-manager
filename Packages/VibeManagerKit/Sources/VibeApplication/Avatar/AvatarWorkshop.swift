import Foundation

/// Makes avatars: drawn by an agent, redrawn one expression at a time, read from an archive,
/// written to one (#41).
///
/// Whatever it makes is a candidate: nothing here touches the avatar in use. Every image that comes
/// back passes the same checks, whoever made it.
public struct AvatarWorkshop: Sendable {
  private let processing: any AvatarImageProcessing
  private let diagnostics: Diagnostics
  private let now: @Sendable () -> Date

  public init(
    processing: any AvatarImageProcessing, diagnostics: Diagnostics = .disabled,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.processing = processing
    self.diagnostics = diagnostics
    self.now = now
  }

  /// The whole set, drawn by `generator` from the user's description, in one sheet.
  public func generate(
    description: String, name: String, provider: AgentProviderID,
    with generator: any AvatarGenerating
  ) async throws -> AvatarSpriteSet {
    let expressions = AvatarExpression.allCases
    let prompt = AvatarPrompt.sheet(description: description, expressions: expressions)
    let sheet = try await draw(AvatarGenerationRequest(prompt: prompt), with: generator)
    let sprites: [AvatarExpression: Data]
    do {
      sprites = try processing.sprites(fromSheet: sheet, expressions: expressions)
    } catch let problem as AvatarProblem {
      record("avatar.generationRejected", problem: problem)
      throw AvatarGenerationError.rejected(problem)
    }
    diagnostics.record(
      .lifecycle, .notice, "avatar.generated", ["provider": .token(provider.diagnosticToken)])
    return AvatarSpriteSet(
      manifest: AvatarManifest(
        name: Self.name(name, description: description), source: .generated,
        provider: provider.rawValue, description: AvatarPrompt.sanitizedDescription(description),
        createdAt: now()),
      sprites: sprites, sheet: sheet)
  }

  /// `avatar` with `expression` drawn again, from its sheet — or its neutral sprite — as reference.
  public func regenerate(
    _ expression: AvatarExpression, in avatar: AvatarSpriteSet,
    with generator: any AvatarGenerating
  ) async throws -> AvatarSpriteSet {
    let reference = avatar.sheet ?? avatar.sprites[.neutral] ?? avatar.sprites.values.first
    let prompt = AvatarPrompt.expression(
      expression, description: avatar.manifest.description ?? avatar.manifest.name)
    let image = try await draw(
      AvatarGenerationRequest(prompt: prompt, reference: reference), with: generator)
    let sprite: Data
    do {
      sprite = try processing.sprite(
        fromImage: image, as: expression,
        matching: expression == .neutral ? nil : avatar.sprites[.neutral])
    } catch let problem as AvatarProblem {
      record("avatar.generationRejected", problem: problem)
      throw AvatarGenerationError.rejected(problem)
    }
    var result = avatar
    result.sprites[expression] = sprite
    return result
  }

  /// The avatar an archive holds. Incomplete is allowed: the screen offers to draw what is missing.
  public func importArchive(_ data: Data) throws -> (avatar: AvatarSpriteSet, ignoredFiles: Int) {
    do {
      let result = try processing.avatar(fromArchive: data)
      diagnostics.record(
        .lifecycle, .notice, "avatar.imported",
        [
          "missing": .count(result.avatar.missingExpressions.count),
          "ignored": .count(result.ignoredFiles),
        ])
      return result
    } catch let problem as AvatarProblem {
      record("avatar.importRejected", problem: problem)
      throw problem
    }
  }

  /// The archive of `avatar`, with or without the user's description.
  public func exportArchive(_ avatar: AvatarSpriteSet, includingDescription: Bool) throws -> Data {
    var exported = avatar
    if !includingDescription { exported.manifest.description = nil }
    return try processing.archive(exported)
  }

  private func draw(
    _ request: AvatarGenerationRequest, with generator: any AvatarGenerating
  ) async throws -> Data {
    do {
      return try await generator.generate(request)
    } catch let error as AvatarGenerationError {
      diagnostics.record(
        .lifecycle, .notice, "avatar.generationFailed", ["reason": .token(Self.token(of: error))])
      throw error
    }
  }

  private func record(_ name: StaticString, problem: AvatarProblem) {
    diagnostics.record(.lifecycle, .notice, name, ["reason": .token(Self.token(of: problem))])
  }

  /// The name an avatar gets: the one given, or the start of its description.
  static func name(_ name: String, description: String) -> String {
    let given = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = given.isEmpty ? AvatarPrompt.sanitizedDescription(description) : given
    let line = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return String(line.prefix(AvatarManifest.maximumNameLength))
  }

  static func token(of error: AvatarGenerationError) -> DiagnosticToken {
    switch error {
    case .unavailable: return "unavailable"
    case .timedOut: return "timedOut"
    case .noImage: return "noImage"
    case .failed: return "failed"
    case .rejected(let problem): return token(of: problem)
    }
  }

  static func token(of problem: AvatarProblem) -> DiagnosticToken {
    switch problem {
    case .unreadableImage: return "unreadableImage"
    case .imageTooLarge: return "imageTooLarge"
    case .wrongGrid: return "wrongGrid"
    case .cellTooSmall: return "cellTooSmall"
    case .emptyCell: return "emptyCell"
    case .cutCell: return "cutCell"
    case .inconsistentSize: return "inconsistentSize"
    case .backgroundNotRemoved: return "backgroundNotRemoved"
    case .archiveUnreadable: return "archiveUnreadable"
    case .archiveTooLarge: return "archiveTooLarge"
    case .archiveUnsafeEntry: return "archiveUnsafeEntry"
    case .archiveEncrypted: return "archiveEncrypted"
    case .archiveFromNewerVersion: return "archiveFromNewerVersion"
    case .archiveHasNoImage: return "archiveHasNoImage"
    case .imageNotSquare: return "imageNotSquare"
    case .imageTooSmall: return "imageTooSmall"
    case .imagesOfDifferentSizes: return "imagesOfDifferentSizes"
    case .duplicateExpression: return "duplicateExpression"
    }
  }
}
