#if os(macOS)
  import Darwin
  import Foundation
  import Security

  /// Decides whether the process at the other end of the link may talk to this one.
  public protocol CompanionPeerVerifying: Sendable {
    func accepts(peerOf descriptor: Int32) -> Bool
  }

  /// The same user, and nothing else checked: for tests, where both ends are one test binary.
  public struct SameUserCompanionPeerVerifier: CompanionPeerVerifying {
    public init() {
      // Nothing to hold: the answer is read from the socket each time.
    }

    public func accepts(peerOf descriptor: Int32) -> Bool {
      CompanionSocket.peerUserIdentifier(of: descriptor) == getuid()
    }
  }

  /// The same user, running code signed by this process's own team as `peerIdentifier`.
  ///
  /// Each end demands it of the other (#347): the application only talks to its companion agent,
  /// which holds the iCloud entitlement, and the agent only takes sessions and acknowledgements
  /// from the application. The team is read from this process's own signature, so none is written
  /// anywhere; a build signed ad hoc — a contributor's, without a team — demands the identifier
  /// alone, as the terminal host does (`CodeSigningPeerVerifier`), and gives nothing away that a
  /// process of the same user could not already read.
  ///
  /// Unchecked because a `SecRequirement` is an immutable Core Foundation object, safe to share.
  public final class CodeSigningCompanionPeerVerifier: CompanionPeerVerifying, @unchecked Sendable {
    private let requirement: SecRequirement?

    public init(peerIdentifier: String) {
      requirement = Self.requirementText(peerIdentifier: peerIdentifier, team: Self.ownTeam())
        .flatMap { text in
          var requirement: SecRequirement?
          let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
          return status == errSecSuccess ? requirement : nil
        }
    }

    /// What the peer must satisfy: signed by Apple's chain for `team` as `peerIdentifier`, or the
    /// identifier alone without a team. `nil` for an identifier that would break the requirement.
    static func requirementText(peerIdentifier: String, team: String?) -> String? {
      let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
      guard !peerIdentifier.isEmpty,
        peerIdentifier.unicodeScalars.allSatisfy(allowed.contains)
      else { return nil }
      guard let team else { return "identifier \"\(peerIdentifier)\"" }
      guard !team.isEmpty, team.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
      else { return nil }
      return
        "anchor apple generic and identifier \"\(peerIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    public func accepts(peerOf descriptor: Int32) -> Bool {
      guard CompanionSocket.peerUserIdentifier(of: descriptor) == getuid() else { return false }
      guard let requirement, var token = CompanionSocket.peerAuditToken(of: descriptor) else {
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

    /// The team this process is signed by, `nil` signed ad hoc.
    private static func ownTeam() -> String? {
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
      return information[kSecCodeInfoTeamIdentifier as String] as? String
    }
  }
#endif
