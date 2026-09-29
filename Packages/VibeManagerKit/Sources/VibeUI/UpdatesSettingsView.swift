import SwiftUI
import VibeApplication

/// The Updates tab (#92): whether and how often to look, whether to download by itself, which
/// channel, and when it last looked.
struct UpdatesSettingsView: View {
  let updates: UpdatesModel

  var body: some View {
    Form {
      if case .unavailable(let reason) = updates.availability {
        Section {
          Text(Self.explanation(of: reason))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Section {
        Toggle(isOn: binding(\.automaticallyChecks)) {
          Text("Check for updates automatically", bundle: .module)
        }
        Picker(selection: binding(\.interval)) {
          Text("Daily", bundle: .module, comment: "How often to check for updates.")
            .tag(UpdateCheckInterval.daily)
          Text("Weekly", bundle: .module, comment: "How often to check for updates.")
            .tag(UpdateCheckInterval.weekly)
          Text("Monthly", bundle: .module, comment: "How often to check for updates.")
            .tag(UpdateCheckInterval.monthly)
        } label: {
          Text("Check", bundle: .module, comment: "Followed by how often: Daily, Weekly, Monthly.")
        }
        .disabled(!updates.settings.automaticallyChecks)
        Toggle(isOn: binding(\.automaticallyDownloads)) {
          Text("Download and install updates automatically", bundle: .module)
          Text(
            """
            A new version is downloaded in the background and installed the next time you quit \
            Vibe Manager. Turned off, you are told first.
            """,
            bundle: .module)
        }
      } header: {
        Text("Updates", bundle: .module, comment: "A section of the Settings window.")
      }
      Section {
        Picker(selection: binding(\.channel)) {
          Text("Stable", bundle: .module, comment: "An update channel: final versions only.")
            .tag(UpdateChannel.stable)
          Text(
            "Unstable", bundle: .module,
            comment: "An update channel: release candidates as well as final versions."
          )
          .tag(UpdateChannel.unstable)
        } label: {
          Text("Channel", bundle: .module, comment: "Which versions are offered as updates.")
          Text(
            """
            Unstable also offers the release candidates: versions still being tested before they \
            are final, which may have defects.
            """,
            bundle: .module)
        }
      }
      Section {
        LabeledContent {
          Button {
            updates.checkNow()
          } label: {
            Text("Check Now", bundle: .module)
          }
          .disabled(!updates.canCheck)
        } label: {
          if let waiting = updates.waitingVersion {
            Text("Version \(waiting) is available.", bundle: .module)
          } else if let last = updates.lastCheck {
            Text("Last checked \(last.formatted(.relative(presentation: .named)))", bundle: .module)
          } else {
            Text("Never checked", bundle: .module)
          }
          Text(
            """
            Agents running when an update is installed keep running if you choose to: you are \
            asked first, as when quitting, and they are back on screen after the relaunch.
            """,
            bundle: .module)
        }
      }
    }
    .formStyle(.grouped)
    .disabled(!updates.isAvailable)
    .scrollDisabled(true)
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: SettingsView.formWidth)
  }

  private func binding<Value>(_ keyPath: WritableKeyPath<UpdateSettings, Value>) -> Binding<Value> {
    Binding(
      get: { updates.settings[keyPath: keyPath] },
      set: { value in updates.change { $0[keyPath: keyPath] = value } })
  }

  static func explanation(of reason: UpdateAvailability.Reason) -> LocalizedStringResource {
    switch reason {
    case .developmentBuild:
      LocalizedStringResource(
        """
        This copy of Vibe Manager was built from its source, and is never replaced by a release. \
        Updates come to the copies downloaded from GitHub.
        """,
        bundle: .module)
    case .isolatedCopy:
      LocalizedStringResource(
        """
        This copy keeps its data apart (VIBE_DATA_DIRECTORY), and does not update itself: the \
        copy it runs beside does.
        """,
        bundle: .module)
    case .turnedOff:
      LocalizedStringResource(
        "Updates are turned off for this copy (VIBE_UPDATES=off).", bundle: .module)
    case .notConfigured:
      LocalizedStringResource(
        "This build has no key to check updates with, so it does not look for any.",
        bundle: .module)
    case .failed:
      LocalizedStringResource(
        """
        Updates could not be started in this copy. The next version can still be downloaded from \
        GitHub.
        """,
        bundle: .module)
    }
  }
}
