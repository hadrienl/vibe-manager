public struct AgentProviderID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String {
    rawValue
  }
}

public struct AgentVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(major: Int, minor: Int = 0, patch: Int = 0) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  /// Extracts the first `major.minor[.patch]` sequence found in a command line output.
  ///
  /// Parsing stays deliberately tolerant: agent CLIs surround their version with product
  /// names, build metadata or pre-release tags, and none of that must make an otherwise
  /// working binary look unusable.
  /// - Parameter anchor: when several lines carry a number, the line mentioning this token
  ///   wins. It keeps a warning such as `requires Node 18.0.0` from being read as the
  ///   version of the agent, which would wrongly mark it as outdated.
  public init?(parsing output: String, anchor: String? = nil) {
    let lines = output.split(whereSeparator: \.isNewline).map(String.init)
    let anchored = anchor.flatMap { anchor in
      lines.first { $0.localizedCaseInsensitiveContains(anchor) }
    }
    let searched = [anchored].compactMap { $0 } + lines

    for line in searched {
      guard let parsed = Self.firstVersion(in: line) else { continue }
      self = parsed
      return
    }
    return nil
  }

  public var description: String {
    "\(major).\(minor).\(patch)"
  }

  public static func < (lhs: AgentVersion, rhs: AgentVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }

  private static func firstVersion(in output: String) -> AgentVersion? {
    let candidates = output.split(whereSeparator: { !$0.isNumber && $0 != "." })
    for candidate in candidates {
      let components = candidate.split(separator: ".", omittingEmptySubsequences: false)
      let numbers = components.compactMap { Int($0) }
      guard numbers.count == components.count, numbers.count >= 2 else { continue }
      return AgentVersion(
        major: numbers[0],
        minor: numbers[1],
        patch: numbers.count > 2 ? numbers[2] : 0
      )
    }
    return nil
  }
}

public struct AgentModel: Hashable, Sendable, Identifiable {
  public let id: String
  public let displayName: String
  public let isDefault: Bool

  public init(id: String, displayName: String, isDefault: Bool = false) {
    self.id = id
    self.displayName = displayName
    self.isDefault = isDefault
  }
}

public struct AgentCapabilities: Hashable, Sendable {
  public let supportsModelSelection: Bool
  public let supportsInitialPrompt: Bool
  public let supportsResume: Bool
  public let reportsUsage: Bool
  /// Whether the CLI can be given folders beyond its working directory — `--add-dir` for both
  /// Claude Code and Codex. Without it, a session's other repositories are out of the agent's
  /// reach, and the sheet says so instead of letting the user believe otherwise.
  public let supportsAdditionalDirectories: Bool

  public init(
    supportsModelSelection: Bool = false,
    supportsInitialPrompt: Bool = false,
    supportsResume: Bool = false,
    reportsUsage: Bool = false,
    supportsAdditionalDirectories: Bool = false
  ) {
    self.supportsModelSelection = supportsModelSelection
    self.supportsInitialPrompt = supportsInitialPrompt
    self.supportsResume = supportsResume
    self.reportsUsage = reportsUsage
    self.supportsAdditionalDirectories = supportsAdditionalDirectories
  }
}

public struct AgentDescriptor: Hashable, Sendable, Identifiable {
  public let id: AgentProviderID
  public let displayName: String
  public let symbolName: String
  public let minimumVersion: AgentVersion?
  public let capabilities: AgentCapabilities

  public init(
    id: AgentProviderID,
    displayName: String,
    symbolName: String = "sparkles",
    minimumVersion: AgentVersion? = nil,
    capabilities: AgentCapabilities = AgentCapabilities()
  ) {
    self.id = id
    self.displayName = displayName
    self.symbolName = symbolName
    self.minimumVersion = minimumVersion
    self.capabilities = capabilities
  }
}
