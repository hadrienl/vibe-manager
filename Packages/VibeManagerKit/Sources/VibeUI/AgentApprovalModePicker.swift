import SwiftUI
import VibeDomain

/// Shared by native agents and endpoints that offer their CLI's automatic permission review.
///
/// A native agent also offers its CLI's own setting, the default: Vibe Manager then leaves the
/// CLI's configuration as the user made it. An endpoint's harness is Vibe Manager's to set.
struct AgentApprovalModePicker: View {
  @Binding var selection: AgentApprovalMode?
  var offersCLISetting = true

  var body: some View {
    Picker(selection: $selection) {
      if offersCLISetting {
        Text(
          "As Set in the CLI", bundle: .module,
          comment: "An approval mode: the agent's command-line tool's own setting applies."
        ).tag(AgentApprovalMode?.none)
      }
      Text("Manual", bundle: .module).tag(AgentApprovalMode?.some(.manual))
      Text("Automatic", bundle: .module).tag(AgentApprovalMode?.some(.autoReview))
    } label: {
      Text("Approval mode", bundle: .module)
    }
    Text(
      "Auto reviews permission requests for you while keeping the sandbox. Changes apply to new or restarted sessions.",
      bundle: .module
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }
}

extension AgentApprovalModePicker {
  /// An endpoint's mode, always set.
  init(selection: Binding<AgentApprovalMode>) {
    self.init(
      selection: Binding(
        get: { selection.wrappedValue },
        set: { if let mode = $0 { selection.wrappedValue = mode } }),
      offersCLISetting: false)
  }
}
