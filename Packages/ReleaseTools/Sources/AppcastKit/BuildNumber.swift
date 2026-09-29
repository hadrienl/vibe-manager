import Foundation

/// A `CFBundleVersion` as `Scripts/release.sh` writes it: the number of commits of `main`, followed
/// by `.1` for a final version, which comes after the release candidate of the same commit.
///
/// Compared number by number, as Sparkle compares them: `140` < `140.1` < `141`.
public struct BuildNumber: Comparable, CustomStringConvertible, Sendable {
  public let components: [Int]
  public let description: String

  public init?(_ text: String) {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty,
      parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } })
    else { return nil }
    let numbers = parts.compactMap { Int($0) }
    guard numbers.count == parts.count else { return nil }
    components = numbers
    description = text
  }

  public static func < (lhs: BuildNumber, rhs: BuildNumber) -> Bool {
    for index in 0..<max(lhs.components.count, rhs.components.count) {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right { return left < right }
    }
    return false
  }

  public static func == (lhs: BuildNumber, rhs: BuildNumber) -> Bool {
    !(lhs < rhs) && !(rhs < lhs)
  }
}
