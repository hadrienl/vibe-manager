import Foundation
import Security
import VibeApplication

/// What a diagnostic says about the application itself: nothing about the user.
public struct ApplicationFacts: Hashable, Sendable {
  public enum Signature: String, Hashable, Sendable, DiagnosticTokenConvertible {
    /// Signed by a team: a Developer ID release, or a build signed with a development certificate.
    case team
    /// Signed without an identity, as a local build is.
    case adhoc
    case unsigned
  }

  public let version: String
  public let build: String
  public let operatingSystem: String
  public let architecture: String
  public let signature: Signature
  public let teamIdentifier: String?
  public let hardenedRuntime: Bool

  public init(
    version: String,
    build: String,
    operatingSystem: String,
    architecture: String,
    signature: Signature,
    teamIdentifier: String?,
    hardenedRuntime: Bool
  ) {
    self.version = version
    self.build = build
    self.operatingSystem = operatingSystem
    self.architecture = architecture
    self.signature = signature
    self.teamIdentifier = teamIdentifier
    self.hardenedRuntime = hardenedRuntime
  }

  /// The running binary's.
  public static func current(bundle: Bundle = .main) -> ApplicationFacts {
    let info = bundle.infoDictionary
    let system = ProcessInfo.processInfo.operatingSystemVersion
    let signing = signingInformation()
    return ApplicationFacts(
      version: info?["CFBundleShortVersionString"] as? String ?? "0",
      build: info?["CFBundleVersion"] as? String ?? "0",
      operatingSystem: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
      architecture: architectureName(),
      signature: signing.signature,
      teamIdentifier: signing.team,
      hardenedRuntime: signing.hardened
    )
  }

  /// The launch event: every value through the types the log accepts.
  public var launchFields: [(name: StaticString, value: DiagnosticValue)] {
    var fields: [(name: StaticString, value: DiagnosticValue)] = [
      ("signature", .token(signature.diagnosticToken)),
      ("hardenedRuntime", .flag(hardenedRuntime)),
      ("architecture", .token(architecture == "arm64" ? "arm64" : "x86_64")),
    ]
    if let value = DiagnosticVersion(version) { fields.append(("version", .version(value))) }
    if let value = DiagnosticVersion(build) { fields.append(("build", .version(value))) }
    if let value = DiagnosticVersion(operatingSystem) { fields.append(("macOS", .version(value))) }
    return fields
  }

  private static func architectureName() -> String {
    #if arch(arm64)
      return "arm64"
    #else
      return "x86_64"
    #endif
  }

  private static func signingInformation() -> (
    signature: Signature, team: String?, hardened: Bool
  ) {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
      return (.unsigned, nil, false)
    }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      return (.unsigned, nil, false)
    }
    var information: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
      let dictionary = information as? [String: Any]
    else { return (.unsigned, nil, false) }

    let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    // `kSecCodeSignatureRuntime`: the hardened runtime.
    let codeFlags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    let hardened = codeFlags & 0x10000 != 0
    if dictionary[kSecCodeInfoIdentifier as String] == nil {
      return (.unsigned, nil, false)
    }
    return (team == nil ? .adhoc : .team, team, hardened)
  }
}
