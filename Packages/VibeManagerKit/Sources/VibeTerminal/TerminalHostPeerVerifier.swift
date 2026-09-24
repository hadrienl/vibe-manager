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

/// The same user, running code that satisfies this process's own designated requirement.
///
/// The host is the application's own binary in another mode (ADR 0016), so each end can demand of
/// the other exactly what it is itself, without a team identifier written anywhere: a build signed
/// by a team requires that bundle identifier and that team, and an ad-hoc build requires its own
/// hash — which a later ad-hoc build does not have, and so cannot pass for.
///
/// Unchecked because a `SecRequirement` is an immutable Core Foundation object, safe to share.
public final class CodeSigningPeerVerifier: TerminalHostPeerVerifier, @unchecked Sendable {
  private let requirement: SecRequirement?

  public init() {
    requirement = Self.ownDesignatedRequirement()
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

  private static func ownDesignatedRequirement() -> SecRequirement? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      return nil
    }
    var requirement: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else {
      return nil
    }
    return requirement
  }
}
