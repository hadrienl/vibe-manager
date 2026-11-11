import SwiftUI
import VibeDomain

/// Shared by the native Codex agent and endpoints that use its harness.
struct CodexApprovalModePicker: View {
  @Binding var selection: CodexApprovalMode

  var body: some View {
    Picker(selection: $selection) {
      Text("Manual", bundle: .module).tag(CodexApprovalMode.manual)
      Text("Automatic", bundle: .module).tag(CodexApprovalMode.autoReview)
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
