import Observation

/// One value, observed on its own.
@MainActor
@Observable
final class ObservedCell<Value: Equatable> {
  fileprivate(set) var value: Value?

  fileprivate init() {}
}

/// Values by key, each of which is observed on its own (#254): a view that reads one session's
/// value depends on that session alone.
///
/// A dictionary held by an `@Observable` model is observed as a whole: `values[a] = x` wakes
/// every view that read `values[b]`, and does so even when `x` is what `values[a]` already held.
/// The cells themselves are not observed; each one is, and is only written when its value changes.
@MainActor
final class ObservedCells<Key: Hashable, Value: Equatable> {
  private var cells: [Key: ObservedCell<Value>] = [:]

  init() {}

  /// The value for `key`. The cell is made on the way when there is none yet, so that a view
  /// which read nothing is still told of the first value written.
  func value(for key: Key) -> Value? {
    cell(key).value
  }

  /// Writes `value` for `key`, and nothing when it is the value already there.
  ///
  /// - Returns: whether the value changed.
  @discardableResult
  func set(_ value: Value?, for key: Key) -> Bool {
    let cell = cell(key)
    guard cell.value != value else { return false }
    cell.value = value
    return true
  }

  /// Every value at once, the empty cells left out: for code that is not a view.
  var snapshot: [Key: Value] {
    cells.compactMapValues(\.value)
  }

  /// Writes every value of `values`, and empties the cells of the keys it does not hold.
  func replace(with values: [Key: Value]) {
    for key in cells.keys where values[key] == nil {
      set(nil, for: key)
    }
    for (key, value) in values {
      set(value, for: key)
    }
  }

  private func cell(_ key: Key) -> ObservedCell<Value> {
    if let cell = cells[key] { return cell }
    let cell = ObservedCell<Value>()
    cells[key] = cell
    return cell
  }
}
