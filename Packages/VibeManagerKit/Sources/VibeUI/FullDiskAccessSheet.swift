import SwiftUI

/// The one time the application asks for file access, and it asks for all of it at once.
///
/// macOS has no way to grant "the folders my agents will read": the only permission that covers
/// them is Full Disk Access, the one Terminal, iTerm2 and Ghostty ask for. It cannot be requested
/// programmatically, so the step explains it, opens the right pane, and says plainly that the
/// change lands at the next launch.
///
/// Skipping is offered on equal footing, because refusing is a working answer: repositories are
/// almost never in a protected folder, and the user who says no will simply never see an alert.
struct FullDiskAccessSheet: View {
  let openSystemSettings: () -> Void
  let skip: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Let agents read your folders")
        .font(.title2.weight(.semibold))

      Text(
        """
        Vibe Manager runs coding agents on your behalf. macOS asks for permission every time one \
        of them reads your Desktop, Documents, Downloads, an external disk or iCloud Drive — and \
        it asks in the name of this application, once per folder.
        """
      )
      .fixedSize(horizontal: false, vertical: true)

      Text(
        """
        Granting Full Disk Access once, as you would for Terminal, replaces all of those alerts.
        """
      )
      .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 6) {
        step(1, "Open Privacy & Security → Full Disk Access.")
        step(2, "Turn Vibe Manager on.")
        step(3, "Reopen Vibe Manager — the change takes effect then.")
      }
      .padding(.vertical, 2)

      Text(
        """
        You can skip this. Agents still run, and macOS only asks when one of them reaches a \
        protected folder. You can come back to it in Settings at any time.
        """
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()
        Button("Not Now", action: skip)
          .keyboardShortcut(.cancelAction)
        Button("Open System Settings", action: openSystemSettings)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 460)
  }

  private func step(_ number: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(number).")
        .monospacedDigit()
        .foregroundStyle(.secondary)
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}
