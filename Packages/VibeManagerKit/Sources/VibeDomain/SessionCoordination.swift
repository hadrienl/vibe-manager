import Foundation

/// The part a session plays in a coordination (#352): it coordinates other sessions, or it is one of
/// them.
///
/// A coordinator is an ordinary session that is also given the tools to create and drive sessions
/// of its own, its children. A child is an ordinary session too: the user opens it, writes to it,
/// renames it, closes it. There is no third level: a child never coordinates.
public enum SessionCoordination: Hashable, Sendable {
  case coordinator
  case child(of: SessionID)

  public var isCoordinator: Bool {
    self == .coordinator
  }

  /// The coordinator a child belongs to.
  public var coordinatorID: SessionID? {
    if case .child(let id) = self { return id }
    return nil
  }
}

extension SessionCoordination: Codable {
  private enum CodingKeys: String, CodingKey {
    case role
    case coordinator
  }

  private enum Role: String, Codable {
    case coordinator
    case child
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Role.self, forKey: .role) {
    case .coordinator:
      self = .coordinator
    case .child:
      self = .child(of: try container.decode(SessionID.self, forKey: .coordinator))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .coordinator:
      try container.encode(Role.coordinator, forKey: .role)
    case .child(let id):
      try container.encode(Role.child, forKey: .role)
      try container.encode(id, forKey: .coordinator)
    }
  }
}
