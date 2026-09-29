/// A semantic version, `1.1.0` or `1.1.0-rc.2`, ordered as semver orders them: a final version
/// after its candidates, and `rc.10` after `rc.9`.
public struct ReleaseVersion: Comparable, Hashable, Sendable {
  public var major: Int
  public var minor: Int
  public var patch: Int
  /// Empty for a final version.
  public var prerelease: [String]

  public var isPrerelease: Bool { !prerelease.isEmpty }

  public init?(_ text: String) {
    // Build metadata takes no part in the order.
    let withoutMetadata =
      text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init) ?? text
    let parts = withoutMetadata.split(
      separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard core.count == 3 else { return nil }
    let numbers = core.compactMap { Self.number(String($0)) }
    guard numbers.count == 3 else { return nil }
    major = numbers[0]
    minor = numbers[1]
    patch = numbers[2]
    if parts.count == 2 {
      prerelease = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
      guard prerelease.allSatisfy({ !$0.isEmpty }) else { return nil }
    } else {
      prerelease = []
    }
  }

  public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
    let lhsCore = [lhs.major, lhs.minor, lhs.patch]
    let rhsCore = [rhs.major, rhs.minor, rhs.patch]
    if lhsCore != rhsCore { return lhsCore.lexicographicallyPrecedes(rhsCore) }
    switch (lhs.isPrerelease, rhs.isPrerelease) {
    case (false, false): return false
    case (true, false): return true
    case (false, true): return false
    case (true, true): break
    }
    for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
      return identifier(left, precedes: right)
    }
    return lhs.prerelease.count < rhs.prerelease.count
  }

  /// Numeric identifiers compare as numbers, and before alphanumeric ones.
  private static func identifier(_ left: String, precedes right: String) -> Bool {
    switch (number(left), number(right)) {
    case (let left?, let right?): return left < right
    case (.some, nil): return true
    case (nil, .some): return false
    case (nil, nil): return Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8))
    }
  }

  private static func number(_ text: String) -> Int? {
    guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
    return Int(text)
  }
}
