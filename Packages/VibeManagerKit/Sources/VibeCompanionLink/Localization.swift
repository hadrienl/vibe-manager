import Foundation

extension LocalizedStringResource.BundleDescription {
  /// This module's resource bundle, where its string catalog is compiled. A string declared
  /// without it is looked up in the application's catalog instead, and is never translated.
  static var module: Self { .atURL(Bundle.module.bundleURL) }
}
