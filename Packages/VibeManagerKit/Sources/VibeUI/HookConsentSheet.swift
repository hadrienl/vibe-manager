import SwiftUI
import VibeApplication

/// Asks, in Vibe Manager's own words, before a CLI's hooks are approved on the user's behalf
/// (#45). Codex would otherwise ask in the terminal, in a screen of its own, where "trust all" is
/// the tempting answer and approves more than these.
struct HookConsentSheet: View {
  let request: HookConsentRequest
  let answer: (AgentHookConsent) -> Void
  @State private var showsCommands = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label {
        Text(
          "Track \(request.agentName) activity?", bundle: .module,
          comment:
            "Title of the sheet asking to approve an agent's hooks; the argument is the agent's name."
        )
        .font(.headline)
      } icon: {
        Image(systemName: "waveform.path.ecg")
      }
      Text(
        """
        To show in the sidebar when \(request.agentName) is working, asks a question or has \
        finished an answer, Vibe Manager adds hooks to its sessions. They only note these moments \
        in a file of Vibe Manager's; they never answer in your place.
        """,
        bundle: .module,
        comment: "Why the hooks are added; the argument is the agent's name.")
      Text(
        """
        \(request.agentName) asks for new hooks to be approved once. Vibe Manager approves these \
        ones, and no other.
        """,
        bundle: .module,
        comment: "What approving does; the argument is the agent's name."
      )
      .foregroundStyle(.secondary)
      DisclosureGroup(isExpanded: $showsCommands) {
        ScrollView {
          Text(verbatim: request.commands.joined(separator: "\n\n"))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
      } label: {
        Text("Commands the hooks run", bundle: .module)
      }
      Text(
        "You can change this later in Settings.", bundle: .module,
        comment: "Under the question about an agent's hooks."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button {
          answer(.declined)
        } label: {
          Text("Not Now", bundle: .module, comment: "Declines to approve an agent's hooks.")
        }
        .keyboardShortcut(.cancelAction)
        Button {
          answer(.approved)
        } label: {
          Text("Track Activity", bundle: .module, comment: "Approves an agent's hooks.")
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 460)
    .accessibilityIdentifier("hook-consent")
  }
}
