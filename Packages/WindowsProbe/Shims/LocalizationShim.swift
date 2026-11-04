import Foundation

// Probe only: stands in for Foundation's Apple-only localization API, to reveal what lies behind
// it. It does not translate anything.
public struct LocalizedStringResource: ExpressibleByStringInterpolation, Sendable, Hashable {
  public enum BundleDescription: Sendable, Hashable { case main, module }
  public var key: String
  public init(stringLiteral value: String) { key = value }
  public init(stringInterpolation: DefaultStringInterpolation) { key = String(stringInterpolation: stringInterpolation) }
  public init(
    _ value: LocalizedStringResource, table: String? = nil, locale: Locale = .current,
    bundle: BundleDescription = .main, comment: StaticString? = nil
  ) { key = value.key }
}

extension String {
  public init(
    localized value: LocalizedStringResource, table: String? = nil,
    bundle: LocalizedStringResource.BundleDescription? = nil, locale: Locale = .current,
    comment: StaticString? = nil
  ) { self = value.key }
}
