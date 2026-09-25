import Foundation
import Security
import VibeApplication

/// Reads the code identity TCC holds this process's grants against.
///
/// Read from the binary on disk: after a rebuild, the process still running from the previous one
/// reads the new identity, which is the one the next launch — and the next host — will have.
public struct SecCodeIdentityReader: CodeIdentityReading {
  public init() {
    // Nothing to hold: the signature is read each time.
  }

  public func current() -> CodeIdentityFingerprint {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unidentified }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      return .unidentified
    }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        == errSecSuccess,
      let information = information as? [String: Any]
    else { return .unidentified }
    let identifier =
      information[kSecCodeInfoIdentifier as String] as? String
      ?? Bundle.main.bundleIdentifier ?? "unsigned"
    // No team is an ad-hoc signature: its designated requirement is its own hash, which the next
    // build does not share.
    guard let team = information[kSecCodeInfoTeamIdentifier as String] as? String else {
      return .adHoc(identifier: identifier)
    }
    var requirement: SecRequirement?
    var text: CFString?
    guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
      let requirement,
      SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
      let text
    else { return .adHoc(identifier: identifier) }
    return CodeIdentityFingerprint(
      identifier: identifier, team: team, designatedRequirement: text as String)
  }
}
