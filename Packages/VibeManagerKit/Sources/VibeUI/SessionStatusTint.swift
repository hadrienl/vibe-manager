import SwiftUI

extension SessionStatusSeverity {
  /// The colour of a state's words and symbol, on its row and on its group's header. Kept in one
  /// place so that its contrast against the sidebar can be measured (#233).
  var tint: Color {
    switch self {
    case .normal: return .secondary
    case .active: return .accentColor
    case .attention: return .orange
    case .error: return .red
    }
  }
}
