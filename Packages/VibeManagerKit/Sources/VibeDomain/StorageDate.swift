import Foundation

extension Date {
  /// The same instant, reduced to the precision the durable store can represent.
  ///
  /// Sessions are persisted with millisecond precision, so a value carrying more precision than
  /// that would not survive a round trip: a reloaded session would never compare equal to the one
  /// it was built from, and every equality check or view diff would report a spurious change.
  /// Domain values are normalized on entry instead, which keeps the persisted document readable
  /// and makes the store's precision the model's precision.
  public var storageRounded: Date {
    Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate * 1000).rounded() / 1000)
  }
}
