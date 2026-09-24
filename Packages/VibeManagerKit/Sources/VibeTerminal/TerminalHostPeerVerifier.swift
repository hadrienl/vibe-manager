import Darwin
import Foundation
import Security

/// Decides whether the process at the other end of a socket may talk to this one.
///
/// Both ends ask it: the host of every client, so that no other program can read a terminal or
/// type into it, and the application of the host, so that a program that bound the socket first
/// is handed neither a keystroke nor an agent's environment.
public protocol TerminalHostPeerVerifier: Sendable {
  func accepts(peerOf descriptor: Int32) -> Bool
}

/// The same user, and nothing else checked. For tests, where the two ends are different binaries.
public struct SameUserPeerVerifier: TerminalHostPeerVerifier {
  public init() {
    // Nothing to hold: the answer is read from the socket each time.
  }

  public func accepts(peerOf descriptor: Int32) -> Bool {
    UnixSocket.peerUserIdentifier(of: descriptor) == getuid()
  }
}

/// The same user, running code signed as this very application.
///
/// The host is the application's own binary in another mode (ADR 0016), so each end demands of
/// the other what it is itself, without a team identifier written anywhere:
///
/// - **signed by a team**, the designated requirement: that bundle identifier and that team. It
///   survives an update, so an application updated while its agents ran reattaches to them;
/// - **signed ad hoc** — a development build — the bundle identifier alone. The designated
///   requirement of such a build is its own hash, which the next build does not have: requiring
///   it would kill every agent left running at each compilation, which is precisely the work this
///   host exists to keep. What the identifier alone lets through is a process of the same user
///   signed ad hoc under that name; such a process can already open the terminal devices it owns,
///   or rewrite the development binary itself, so nothing is given away that was not already.
///
/// Unchecked because a `SecRequirement` is an immutable Core Foundation object, safe to share.
public final class CodeSigningPeerVerifier: TerminalHostPeerVerifier, @unchecked Sendable {
  private let requirement: SecRequirement?

  public init() {
    requirement = Self.ownRequirement()
  }

  public func accepts(peerOf descriptor: Int32) -> Bool {
    guard UnixSocket.peerUserIdentifier(of: descriptor) == getuid() else { return false }
    guard let requirement, var token = UnixSocket.peerAuditToken(of: descriptor) else {
      return false
    }
    let tokenData = withUnsafeBytes(of: &token) { Data($0) }
    let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
    var guest: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
      let guest
    else { return false }
    return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
  }

  private static func ownRequirement() -> SecRequirement? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      return nil
    }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        == errSecSuccess,
      let information = information as? [String: Any]
    else { return nil }

    // A team, and the designated requirement names it: it holds across builds and updates.
    if information[kSecCodeInfoTeamIdentifier as String] is String {
      var requirement: SecRequirement?
      guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else {
        return nil
      }
      return requirement
    }
    guard let identifier = information[kSecCodeInfoIdentifier as String] as? String,
      !identifier.contains("\"")
    else { return nil }
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString("identifier \"\(identifier)\"" as CFString, [], &requirement)
        == errSecSuccess
    else { return nil }
    return requirement
  }
}
