import Foundation

/// A section of the context column (#66): Git, the notes, the agent…
///
/// A string rather than an enum on purpose. A section added by a later build must decode here,
/// be kept where the user put it and be written back as it was, not fail the whole layout.
public struct InspectorSectionID: RawRepresentable, Hashable, Codable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var description: String { rawValue }

  public static let activity = Self("activity")
  public static let git = Self("git")
  public static let notes = Self("notes")
  public static let agent = Self("agent")
  public static let usage = Self("usage")
  public static let prompt = Self("prompt")
}

/// How the user arranged the context column: the order of its sections, which are folded, and
/// what share of the height each unfolded one takes. Common to every session.
///
/// It holds every section it was given, the ones this build does not know or does not show
/// included: a section is never a missing step when moving another, and never lost on the way
/// back from a later version.
public struct InspectorArrangement: Equatable, Codable, Sendable {
  public struct Entry: Equatable, Codable, Sendable {
    public var id: InspectorSectionID
    public var isCollapsed: Bool
    /// A share relative to the other unfolded sections, not a height: the column's height is the
    /// window's, and changes without the arrangement changing.
    public var weight: Double

    public init(id: InspectorSectionID, isCollapsed: Bool, weight: Double = 1) {
      self.id = id
      self.isCollapsed = isCollapsed
      self.weight = weight
    }
  }

  /// In the order they are shown.
  public private(set) var entries: [Entry]

  /// Duplicates keep their first occurrence, and a weight that is not a positive number becomes
  /// 1: an arrangement edited by hand, or written by a broken build, still lays out.
  public init(entries: [Entry]) {
    var seen = Set<InspectorSectionID>()
    self.entries = entries.compactMap { entry in
      guard seen.insert(entry.id).inserted else { return nil }
      var entry = entry
      entry.weight = Self.valid(entry.weight)
      return entry
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Entry by entry: one that cannot be read costs that section its arrangement, not the rest.
    let entries = try container.decode([Lossy<Entry>].self, forKey: .entries)
    self.init(entries: entries.compactMap(\.value))
  }

  private enum CodingKeys: String, CodingKey {
    case entries
  }

  /// Activity, Git and the notes unfolded, in that order; the agent, its usage and the prompt it
  /// started from folded under them. Git takes a little more of the height: it is the longest.
  public static let `default` = InspectorArrangement(entries: [
    Entry(id: .activity, isCollapsed: false, weight: 1),
    Entry(id: .git, isCollapsed: false, weight: 1.4),
    Entry(id: .notes, isCollapsed: false, weight: 1),
    Entry(id: .agent, isCollapsed: true),
    Entry(id: .usage, isCollapsed: true),
    Entry(id: .prompt, isCollapsed: true),
  ])

  public func entry(_ id: InspectorSectionID) -> Entry? {
    entries.first { $0.id == id }
  }

  public func isCollapsed(_ id: InspectorSectionID) -> Bool {
    (entry(id) ?? Self.defaultEntry(id)).isCollapsed
  }

  public func weight(_ id: InspectorSectionID) -> Double {
    (entry(id) ?? Self.defaultEntry(id)).weight
  }

  /// The arrangement with every section of `declared` in it. A section it did not know yet — new
  /// in this build — goes right after the section declared before it, with its default state:
  /// where it would be in a fresh arrangement, as close as the user's order allows.
  public func resolved(declared: [InspectorSectionID]) -> InspectorArrangement {
    var entries = entries
    for (index, id) in declared.enumerated() where !entries.contains(where: { $0.id == id }) {
      let previous = declared[..<index].last { id in entries.contains { $0.id == id } }
      let position =
        previous.flatMap { previous in entries.firstIndex { $0.id == previous } }.map { $0 + 1 }
        ?? 0
      entries.insert(Self.defaultEntry(id), at: position)
    }
    return InspectorArrangement(entries: entries)
  }

  /// The sections of `shown`, in the arrangement's order. One the arrangement does not hold yet
  /// takes its place as `resolved` would put it.
  public func order(of shown: [InspectorSectionID]) -> [InspectorSectionID] {
    let wanted = Set(shown)
    return resolved(declared: shown).entries.map(\.id).filter { wanted.contains($0) }
  }

  // MARK: - Folding

  public mutating func setCollapsed(_ id: InspectorSectionID, _ isCollapsed: Bool) {
    update(id) { $0.isCollapsed = isCollapsed }
  }

  /// ⌥-click on a chevron: every section shown folds, or unfolds.
  public mutating func setCollapsed(_ isCollapsed: Bool, among shown: [InspectorSectionID]) {
    for id in shown {
      setCollapsed(id, isCollapsed)
    }
  }

  /// Collapse Others: this one unfolded, every other shown one folded.
  public mutating func collapseOthers(
    than kept: InspectorSectionID, among shown: [InspectorSectionID]
  ) {
    for id in shown {
      setCollapsed(id, id != kept)
    }
  }

  // MARK: - Moving

  /// Whether Move Up (`-1`) or Move Down (`+1`) has somewhere to go, among the sections shown.
  public func canMove(_ id: InspectorSectionID, by offset: Int, among shown: [InspectorSectionID])
    -> Bool
  {
    let order = order(of: shown)
    guard let index = order.firstIndex(of: id) else { return false }
    return order.indices.contains(index + offset)
  }

  /// Move Up and Move Down step over the sections shown only: a section this build does not know,
  /// or cannot show, is never an invisible step.
  public mutating func move(
    _ id: InspectorSectionID, by offset: Int, among shown: [InspectorSectionID]
  ) {
    let order = order(of: shown)
    guard offset != 0, let index = order.firstIndex(of: id), order.indices.contains(index + offset)
    else { return }
    let target = order[index + offset]
    self = resolved(declared: shown)
    if offset < 0 {
      move(id, before: target)
    } else {
      move(id, after: target)
    }
  }

  /// Puts `id` right after `target`.
  public mutating func move(_ id: InspectorSectionID, after target: InspectorSectionID) {
    guard id != target else { return }
    let moved = entry(id) ?? Self.defaultEntry(id)
    entries.removeAll { $0.id == id }
    let position = entries.firstIndex { $0.id == target }.map { $0 + 1 }
    entries.insert(moved, at: position ?? entries.endIndex)
  }

  /// Puts `id` right before `target`, or last when there is none: what a drop on a header does.
  public mutating func move(_ id: InspectorSectionID, before target: InspectorSectionID?) {
    guard id != target else { return }
    let moved = entry(id) ?? Self.defaultEntry(id)
    entries.removeAll { $0.id == id }
    let position = target.flatMap { target in entries.firstIndex { $0.id == target } }
    entries.insert(moved, at: position ?? entries.endIndex)
  }

  // MARK: - Resizing

  /// A handle dragged between two sections: their new heights become their weights, and every
  /// other unfolded section keeps the height it had, its weight rewritten in the same unit.
  public mutating func resize(to heights: [InspectorSectionID: Double]) {
    let heights = heights.filter { $0.value.isFinite && $0.value > 0 }
    guard !heights.isEmpty else { return }
    // The other sections, folded or hidden, are brought to the same unit, so that one unfolded
    // later still gets the share it had before the resize.
    let scale = heights.values.reduce(0, +) / heights.keys.reduce(0) { $0 + weight($1) }
    for index in entries.indices where heights[entries[index].id] == nil {
      entries[index].weight = Self.valid(entries[index].weight * scale)
    }
    for (id, height) in heights {
      update(id) { $0.weight = height }
    }
  }

  // MARK: -

  private mutating func update(_ id: InspectorSectionID, _ change: (inout Entry) -> Void) {
    if let index = entries.firstIndex(where: { $0.id == id }) {
      change(&entries[index])
      entries[index].weight = Self.valid(entries[index].weight)
    } else {
      var entry = Self.defaultEntry(id)
      change(&entry)
      entry.weight = Self.valid(entry.weight)
      entries.append(entry)
    }
  }

  /// What a section starts with: its default for the ones this build ships, unfolded otherwise.
  static func defaultEntry(_ id: InspectorSectionID) -> Entry {
    Self.default.entries.first { $0.id == id } ?? Entry(id: id, isCollapsed: false)
  }

  private static func valid(_ weight: Double) -> Double {
    weight.isFinite && weight > 0 ? weight : 1
  }
}

/// Decodes to `nil` rather than failing the array it is in.
private struct Lossy<Value: Decodable>: Decodable {
  let value: Value?

  init(from decoder: any Decoder) throws {
    value = try? Value(from: decoder)
  }
}

/// How much height each unfolded section is given (#66): a pure function, so that the rule is
/// tested without a window.
public enum InspectorHeights {
  public struct Demand: Equatable, Sendable {
    public let id: InspectorSectionID
    public let weight: Double
    public let minimum: Double
    /// The height of its content, for a section that never needs more; `nil` for one that takes
    /// whatever it is given — a list, an editor.
    public let maximum: Double?

    public init(id: InspectorSectionID, weight: Double, minimum: Double, maximum: Double? = nil) {
      self.id = id
      self.weight = weight.isFinite && weight > 0 ? weight : 1
      let minimum = max(0, minimum.isFinite ? minimum : 0)
      self.minimum = minimum
      self.maximum = maximum.flatMap { $0.isFinite ? max($0, minimum) : nil }
    }
  }

  /// Shares `available` in proportion to the weights. A section is never given less than its
  /// minimum — when the minimums do not fit, each gets its own and the column scrolls — nor more
  /// than its content: what it does not take goes to the others, and what nobody takes is left
  /// empty at the bottom.
  public static func distribute(_ available: Double, among demands: [Demand])
    -> [InspectorSectionID: Double]
  {
    var heights: [InspectorSectionID: Double] = [:]
    var remaining = max(0, available.isFinite ? available : 0)
    var free = demands
    // Each pass settles at least one section for good, so this ends.
    while !free.isEmpty {
      let totalWeight = free.reduce(0) { $0 + $1.weight }
      let share = { (demand: Demand) in remaining * demand.weight / totalWeight }
      let starved = free.filter { share($0) < $0.minimum }
      let sated = free.filter { demand in demand.maximum.map { share(demand) > $0 } ?? false }
      // The minimums first: settling a starved section only takes room from the others, which
      // can make a section that looked sated no longer so.
      let settled =
        starved.isEmpty ? sated.map { ($0, $0.maximum ?? 0) } : starved.map { ($0, $0.minimum) }
      guard !settled.isEmpty else {
        for demand in free {
          heights[demand.id] = share(demand)
        }
        break
      }
      for (demand, height) in settled {
        heights[demand.id] = height
        remaining = max(0, remaining - height)
      }
      let ids = Set(settled.map(\.0.id))
      free.removeAll { ids.contains($0.id) }
    }
    return heights
  }
}
