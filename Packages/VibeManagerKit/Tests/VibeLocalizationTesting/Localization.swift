import Foundation

/// Resolves a string in a language of the tests' choosing, from the catalog of the module that
/// declared it.
///
/// `String(localized:bundle:locale:)` cannot do it: its locale only formats the arguments, and the
/// table is still the one of the process's language — English, in a test runner whose own bundle
/// declares no localization. The table of a language lives in the `<language>.lproj` sub-bundle of
/// the module's resource bundle, so that is where the lookup is pointed.
public enum Localization {
  /// `resource` as the application shows it in `language`: `"en"` or `"fr"`.
  public static func string(_ resource: LocalizedStringResource, in language: String) -> String {
    let bundle: Bundle
    switch resource.bundle {
    case .atURL(let url):
      bundle = Bundle(url: url) ?? .main
    case .forClass(let type):
      bundle = Bundle(for: type)
    default:
      bundle = .main
    }
    return string(resource.defaultValue, table: resource.table, bundle: bundle, in: language)
  }

  /// A string a module resolves with `String(localized:bundle:)` — an error message, say — as the
  /// application shows it in `language`. `module` is the target's name: `"VibeDomain"`.
  public static func string(
    _ value: String.LocalizationValue, module: String, in language: String
  ) -> String {
    string(value, table: nil, bundle: moduleBundle(module), in: language)
  }

  /// The resource bundle SwiftPM builds for `module`, copied next to the tests.
  public static func moduleBundle(_ module: String) -> Bundle {
    let name = "VibeManagerKit_\(module).bundle"
    let candidates =
      [Bundle(for: BundleMarker.self).resourceURL, Bundle.main.resourceURL]
      + Bundle.allBundles.map(\.resourceURL)
    for candidate in candidates.compactMap({ $0 }) {
      if let bundle = Bundle(url: candidate.appendingPathComponent(name)) {
        return bundle
      }
    }
    preconditionFailure("No resource bundle named \(name) next to the tests.")
  }

  private static func string(
    _ value: String.LocalizationValue, table: String?, bundle: Bundle, in language: String
  ) -> String {
    // English has no table of its own for a string without plural variants: its text is the key,
    // which a bundle without any table returns.
    let languageBundle = bundle.path(forResource: language, ofType: "lproj").flatMap(
      Bundle.init(path:))
    precondition(
      languageBundle != nil || language == "en", "\(bundle.bundlePath) has no \(language).lproj.")
    return String(
      localized: value, table: table, bundle: languageBundle ?? Bundle(for: BundleMarker.self),
      locale: Locale(identifier: language))
  }
}

private final class BundleMarker {}
