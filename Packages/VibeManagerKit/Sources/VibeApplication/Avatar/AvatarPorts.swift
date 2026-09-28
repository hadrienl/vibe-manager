import Foundation

/// Why an agent cannot draw an avatar now.
public enum AvatarGenerationUnavailability: Hashable, Sendable {
  /// This agent's CLI produces no image.
  case notCapable
  case missing
  case outdated
  case signedOut
}

/// Why a generation gave nothing usable. The current avatar is untouched either way.
public enum AvatarGenerationError: Error, Hashable, Sendable {
  case unavailable(AvatarGenerationUnavailability)
  /// The agent did not answer in time.
  case timedOut
  /// The agent finished without writing the image.
  case noImage
  /// The agent failed; the words are for the diagnostics, never shown as they are.
  case failed(String)
  /// An image came back, and it cannot be an avatar.
  case rejected(AvatarProblem)
}

/// What one generation asks: the whole prompt, and the image to draw from, if any.
public struct AvatarGenerationRequest: Hashable, Sendable {
  public let prompt: String
  /// A PNG the agent is shown as its reference: the current sheet, when one expression is drawn
  /// again.
  public let reference: Data?

  public init(prompt: String, reference: Data? = nil) {
    self.prompt = prompt
    self.reference = reference
  }
}

/// Draws one image with an agent's CLI, outside any session (#41).
public protocol AvatarGenerating: Sendable {
  /// The image the agent wrote, as it wrote it: not yet trusted.
  func generate(_ request: AvatarGenerationRequest) async throws -> Data
}

/// An agent provider that can draw, on the model of `SessionSummarizingProviding`.
public protocol AvatarGeneratingProviding: Sendable {
  func avatarGenerator() -> any AvatarGenerating
}

/// One agent, as the avatar screen lists it.
public struct AvatarGeneratorOption: Identifiable, Sendable {
  public let descriptor: AgentDescriptor
  /// `nil` when it can draw now.
  public let unavailability: AvatarGenerationUnavailability?
  public let generator: (any AvatarGenerating)?

  public var id: AgentProviderID { descriptor.id }

  public init(
    descriptor: AgentDescriptor, unavailability: AvatarGenerationUnavailability?,
    generator: (any AvatarGenerating)?
  ) {
    self.descriptor = descriptor
    self.unavailability = unavailability
    self.generator = generator
  }
}

/// Which agents can draw, and why the others cannot.
public protocol AvatarGeneratorResolving: Sendable {
  func options() async -> [AvatarGeneratorOption]
}

/// The registered agents, each asked whether it draws, then whether it can now.
public struct AgentAvatarGenerators: AvatarGeneratorResolving {
  private let agents: any AgentProviderResolving

  public init(agents: any AgentProviderResolving) {
    self.agents = agents
  }

  public func options() async -> [AvatarGeneratorOption] {
    var result: [AvatarGeneratorOption] = []
    let availabilities = await agents.availabilities()
    for descriptor in await agents.descriptors() {
      guard let provider = await agents.provider(id: descriptor.id),
        let drawing = provider as? any AvatarGeneratingProviding
      else {
        result.append(
          AvatarGeneratorOption(descriptor: descriptor, unavailability: .notCapable, generator: nil)
        )
        continue
      }
      let unavailability = availabilities[descriptor.id].flatMap { Self.unavailability(of: $0) }
      result.append(
        AvatarGeneratorOption(
          descriptor: descriptor, unavailability: unavailability,
          generator: drawing.avatarGenerator()))
    }
    // Those that can draw first: the screen picks the first one.
    return result.sorted { ($0.unavailability == nil ? 0 : 1) < ($1.unavailability == nil ? 0 : 1) }
  }

  static func unavailability(of availability: AgentAvailability)
    -> AvatarGenerationUnavailability?
  {
    switch availability.state {
    case .available:
      return nil
    case .unauthenticated:
      return .signedOut
    case .outdated:
      return .outdated
    case .notFound, .notExecutable, .probeFailed:
      return .missing
    }
  }
}

/// Turns what came back into sprites, and archives into avatars: images and zip files, done by
/// `VibeAvatar`, behind this port so that the rest never decodes a byte (#41).
public protocol AvatarImageProcessing: Sendable {
  /// The sprites of a sheet drawn on the grid of `expressions`, each checked, cut out and framed
  /// the same way.
  func sprites(fromSheet data: Data, expressions: [AvatarExpression]) throws
    -> [AvatarExpression: Data]
  /// One sprite drawn again, framed like `reference` (the set's neutral sprite) when there is one.
  func sprite(fromImage data: Data, as expression: AvatarExpression, matching reference: Data?)
    throws -> Data
  /// The avatar an archive holds, possibly incomplete, and how many of its files were left out.
  func avatar(fromArchive data: Data) throws -> (avatar: AvatarSpriteSet, ignoredFiles: Int)
  /// The archive of an avatar.
  func archive(_ avatar: AvatarSpriteSet) throws -> Data
}

/// Why an avatar of the library cannot be used. The default one is shown meanwhile, and nothing is
/// deleted: the user decides.
public enum AvatarStoreError: Error, Hashable, Sendable {
  case unreadable
  /// It lacks expressions this version shows: kept from an older one.
  case incomplete([AvatarExpression])
}
