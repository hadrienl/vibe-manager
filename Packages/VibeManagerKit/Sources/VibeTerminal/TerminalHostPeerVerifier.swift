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
/// The host is the application's own binary in another mode (ADR 0017), so each end demands of
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
  /// What this process is signed as, and so what its peer must be signed as too.
  struct Identity: Equatable {
    let identifier: String
    /// `nil` for an ad-hoc signature.
    let team: String?
  }

  private let requirement: SecRequirement?
  private let identity: Identity?

  public init() {
    let own = Self.ownSignature()
    requirement = own?.requirement
    identity = own?.identity
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
    let status = SecCodeCheckValidity(guest, [], requirement)
    if status == errSecSuccess { return true }
    // The peer's binary was replaced on disk after it started — a rebuild, an update — which is
    // exactly the host this design exists to keep. Checking what is on disk would reject the very
    // process that is running; the kernel's view of it is what it was launched as, and validated.
    guard status == errSecCSStaticCodeChanged, let identity else { return false }
    return KernelCodeIdentity.read(token) == identity
  }

  private static func ownSignature() -> (requirement: SecRequirement, identity: Identity)? {
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
      let information = information as? [String: Any],
      let identifier = information[kSecCodeInfoIdentifier as String] as? String
    else { return nil }

    // A team, and the designated requirement names it: it holds across builds and updates.
    if let team = information[kSecCodeInfoTeamIdentifier as String] as? String {
      var requirement: SecRequirement?
      guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
        let requirement
      else { return nil }
      return (requirement, Identity(identifier: identifier, team: team))
    }
    guard !identifier.contains("\"") else { return nil }
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString("identifier \"\(identifier)\"" as CFString, [], &requirement)
        == errSecSuccess,
      let requirement
    else { return nil }
    return (requirement, Identity(identifier: identifier, team: nil))
  }
}

/// The code signature of a running process as the kernel holds it, through `csops_audittoken`.
///
/// Private to the system but stable, and looked up rather than linked: without it, a peer whose
/// binary changed on disk is simply refused, as it was before.
enum KernelCodeIdentity {
  private typealias Function =
    @convention(c) (
      pid_t, UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutablePointer<audit_token_t>
    ) -> Int32

  private static let statusOperation: UInt32 = 0
  private static let identityOperation: UInt32 = 11
  private static let teamOperation: UInt32 = 14
  private static let validFlag: UInt32 = 0x1

  static func read(_ token: audit_token_t) -> CodeSigningPeerVerifier.Identity? {
    guard
      let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops_audittoken")
    else { return nil }
    let csops = unsafeBitCast(symbol, to: Function.self)
    var token = token
    let pid = pid_t(bitPattern: token.val.5)

    var flags: UInt32 = 0
    guard csops(pid, statusOperation, &flags, MemoryLayout<UInt32>.size, &token) == 0,
      flags & validFlag != 0,
      let identifier = string(csops, pid, identityOperation, &token)
    else { return nil }
    return CodeSigningPeerVerifier.Identity(
      identifier: identifier, team: string(csops, pid, teamOperation, &token))
  }

  /// The blob the kernel answers with: a magic, a big-endian length, then a C string.
  private static func string(
    _ csops: Function,
    _ pid: pid_t,
    _ operation: UInt32,
    _ token: inout audit_token_t
  ) -> String? {
    var buffer = [UInt8](repeating: 0, count: 1_024)
    let result = buffer.withUnsafeMutableBytes { raw in
      csops(pid, operation, raw.baseAddress, raw.count, &token)
    }
    guard result == 0, buffer.count > 8 else { return nil }
    let text = buffer[8...].prefix { $0 != 0 }
    guard !text.isEmpty else { return nil }
    return String(decoding: text, as: UTF8.self)
  }
}
