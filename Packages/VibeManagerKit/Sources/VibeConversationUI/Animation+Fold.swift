import SwiftUI

extension Animation {
  /// Rows that fold away or unfold: a coordinator's children, its done sessions. Leave it out when
  /// Reduce Motion is on.
  public static let fold = Animation.easeInOut(duration: 0.15)
}
