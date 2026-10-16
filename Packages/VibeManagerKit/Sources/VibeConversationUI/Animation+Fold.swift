import SwiftUI

extension Animation {
  /// Whatever folds away or unfolds, everywhere in the app: a tool block, a subagent, a
  /// coordinator's children, its done sessions. Leave it out when Reduce Motion is on.
  public static let fold = Animation.easeInOut(duration: 0.15)
}
