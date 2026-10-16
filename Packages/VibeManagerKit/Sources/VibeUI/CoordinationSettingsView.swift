import SwiftUI
import VibeApplication

/// Settings › Coordination (#352): how many children of one coordinator may run at once.
struct CoordinationSettingsView: View {
  @Bindable var coordination: CoordinationModel

  var body: some View {
    Form {
      Section {
        Stepper(
          value: $coordination.maximumRunningChildren,
          in: CoordinationLimits.runningChildren
        ) {
          Text(
            "Children running at once: \(coordination.maximumRunningChildren)", bundle: .module,
            comment: "Settings › Coordination: how many child sessions of a coordinator may run.")
          Text(
            "A coordinator starts no more agents than this at once. Each one takes the Mac’s memory and tokens.",
            bundle: .module)
        }
        .accessibilityIdentifier("settings-coordination-limit")
      } header: {
        Text(
          "Coordinator Sessions", bundle: .module, comment: "A section of Settings › Coordination.")
      } footer: {
        Text(
          """
          A coordinator session creates and follows child sessions, one per task. It never answers \
          a child’s permission or question for you: they wait for you in the palette.
          """,
          bundle: .module
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
  }
}
