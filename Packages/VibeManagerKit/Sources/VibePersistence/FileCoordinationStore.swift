import Foundation
import VibeApplication
import VibeDomain

/// What coordinators did and asked for (#352), beside the store: `Coordination/<child>.trace.json`
/// for what was done to each child, at most 200 entries, and `Coordination/wakes.json` for the
/// wake-ups the coordinators wait for.
///
/// A document that cannot be read is an empty one: it held a trace, or a wake-up the coordinator
/// can ask again. It is replaced at the next write.
public actor FileCoordinationStore: CoordinationStore {
  public static let traceLimit = 200

  private let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  public func trace(of child: SessionID) -> [CoordinationTraceEntry] {
    read([CoordinationTraceEntry].self, from: traceURL(child)) ?? []
  }

  public func append(_ entry: CoordinationTraceEntry, to child: SessionID) {
    var entries = trace(of: child)
    entries.append(entry)
    write(Array(entries.suffix(Self.traceLimit)), to: traceURL(child))
  }

  public func wakes() -> [SessionID: CoordinationWake] {
    let stored = read([String: CoordinationWake].self, from: wakesURL) ?? [:]
    var wakes: [SessionID: CoordinationWake] = [:]
    for (key, wake) in stored {
      guard let uuid = UUID(uuidString: key) else { continue }
      wakes[SessionID(rawValue: uuid)] = wake
    }
    return wakes
  }

  public func setWake(_ wake: CoordinationWake?, for coordinator: SessionID) {
    var stored = read([String: CoordinationWake].self, from: wakesURL) ?? [:]
    stored[coordinator.rawValue.uuidString] = wake
    write(stored, to: wakesURL)
  }

  nonisolated func traceURL(_ id: SessionID) -> URL {
    directory.appendingPathComponent("\(id.rawValue.uuidString).trace.json", isDirectory: false)
  }

  private nonisolated var wakesURL: URL {
    directory.appendingPathComponent("wakes.json", isDirectory: false)
  }

  private func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(type, from: data)
  }

  private func write<Value: Encodable>(_ value: Value, to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value) else { return }
    // A lost write costs a line of a trace, or a wake-up the coordinator can ask again.
    try? AtomicFileWriter.write(data, to: url)
  }
}

/// Settings › Coordination: a preference of this Mac (#352).
@MainActor
public final class UserDefaultsCoordinationPreferences: CoordinationPreferences {
  private let defaults: UserDefaults
  private let limitKey = "coordination.maximumRunningChildren.v1"

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var maximumRunningChildren: Int {
    get {
      let stored = defaults.object(forKey: limitKey) as? Int
      return stored.map {
        min(
          max($0, CoordinationLimits.runningChildren.lowerBound),
          CoordinationLimits.runningChildren.upperBound)
      } ?? CoordinationLimits.defaultRunningChildren
    }
    set { defaults.set(newValue, forKey: limitKey) }
  }
}
