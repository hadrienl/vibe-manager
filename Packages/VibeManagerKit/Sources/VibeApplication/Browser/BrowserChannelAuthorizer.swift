import Foundation
import VibeDomain

/// A process, as its ancestry is read: who it is, who started it, and when it started — which is
/// what tells a process apart from a later one that was given the same number.
public struct ProcessLineageEntry: Hashable, Sendable {
  public let processIdentifier: Int32
  public let parentProcessIdentifier: Int32
  /// Seconds and microseconds since 1970, as the kernel keeps it.
  public let startedAt: ProcessStartTime

  public init(processIdentifier: Int32, parentProcessIdentifier: Int32, startedAt: ProcessStartTime)
  {
    self.processIdentifier = processIdentifier
    self.parentProcessIdentifier = parentProcessIdentifier
    self.startedAt = startedAt
  }
}

public struct ProcessStartTime: Hashable, Comparable, Sendable {
  public let seconds: UInt64
  public let microseconds: UInt64

  public init(seconds: UInt64, microseconds: UInt64) {
    self.seconds = seconds
    self.microseconds = microseconds
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.seconds, lhs.microseconds) < (rhs.seconds, rhs.microseconds)
  }
}

/// A process the application started for a session: the agent in its terminal.
public struct SessionProcess: Hashable, Sendable {
  public let sessionID: SessionID
  public let processIdentifier: Int32
  public let startedAt: ProcessStartTime

  public init(sessionID: SessionID, processIdentifier: Int32, startedAt: ProcessStartTime) {
    self.sessionID = sessionID
    self.processIdentifier = processIdentifier
    self.startedAt = startedAt
  }
}

/// Which session a process that connects to the web view's channel belongs to (#69).
///
/// No secret is handed to the agent: a token in its environment can be read by any process of the
/// same user, and one on its command line by any user of the Mac. What cannot be made up is where a
/// process comes from. The bridge the agent starts, the `vibe` command typed in its terminal, a
/// script it runs — all of them descend from the session's terminal, and are accepted for that
/// session alone. A process that left the tree (a daemon that forked twice, and was taken in by
/// `launchd`) is refused, and that is written down as the one limit of the rule.
public enum BrowserChannelAuthorizer {
  /// - Parameter lineage: the connecting process first, then its parent, and so on up to
  ///   `launchd`, as far as it could be read.
  public static func session(
    of lineage: [ProcessLineageEntry],
    among sessions: [SessionProcess]
  ) -> SessionID? {
    guard !lineage.isEmpty else { return nil }
    // Each link must hold: the parent named by the child is the next entry, and it started no
    // later than the child. A parent that started after its child is a number given again to
    // someone else, and the chain breaks there.
    var chain: [ProcessLineageEntry] = [lineage[0]]
    for entry in lineage.dropFirst() {
      guard let child = chain.last,
        child.parentProcessIdentifier == entry.processIdentifier,
        entry.startedAt <= child.startedAt
      else { break }
      chain.append(entry)
    }
    for entry in chain {
      if let session = sessions.first(where: {
        $0.processIdentifier == entry.processIdentifier && $0.startedAt == entry.startedAt
      }) {
        return session.sessionID
      }
    }
    return nil
  }
}
