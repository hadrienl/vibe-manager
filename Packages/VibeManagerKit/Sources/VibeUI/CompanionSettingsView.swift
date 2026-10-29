import SwiftUI
import VibeApplication

/// Settings › iPhone Companion (#397): the companion turned on, what its agent says, and the
/// iPhones that may connect (#398).
struct CompanionSettingsView: View {
  @Bindable var companion: MobileCompanionModel
  @State private var removing: MobileCompanionModel.Phone?

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $companion.isEnabled) {
          Text(
            "Use Vibe Manager from your iPhone", bundle: .module,
            comment: "Settings › iPhone Companion: the switch that turns the companion on.")
          Text(
            "The Vibe Companion app shows this Mac’s sessions, follows their conversations and answers their requests. It finds the Mac through your iCloud account, then talks to it directly.",
            bundle: .module)
        }
        .disabled(!companion.canRun)
        .accessibilityIdentifier("settings-companion-enabled")
        if let unavailable {
          Label(unavailable, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        } else if companion.isEnabled {
          LabeledContent {
            Text(stateText)
          } label: {
            Text("Status", bundle: .module, comment: "Settings › iPhone Companion: a row.")
          }
        }
      } footer: {
        // The alpha test: the app is on TestFlight, not on the App Store yet. The public invitation
        // opens TestFlight straight away; the README's section walks through the whole setup.
        VStack(alignment: .leading, spacing: 6) {
          Text(
            "The companion is in alpha test: the Vibe Companion app is not on the App Store yet. Install it on your iPhone through TestFlight.",
            bundle: .module
          )
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          Button {
            ExternalOpening.open(Self.alphaInstructions)
          } label: {
            Text(
              "How to install the alpha…", bundle: .module,
              comment: "Settings › iPhone Companion: opens the alpha test's instructions on GitHub.")
          }
          .buttonStyle(.link)
          Button {
            ExternalOpening.open(Self.testFlightInvitation)
          } label: {
            Text(
              "Join the TestFlight beta…", bundle: .module,
              comment: "Settings › iPhone Companion: opens the public TestFlight invitation to Vibe Companion.")
          }
          .buttonStyle(.link)
        }
      }
      if companion.isEnabled {
        Section {
          if companion.phones.isEmpty {
            Text(
              "Open Vibe Companion on an iPhone signed in to the same iCloud account: it appears here.",
              bundle: .module
            )
            .foregroundStyle(.secondary)
          }
          ForEach(companion.phones) { phone in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: phone.name)
                Group {
                  if companion.connectedPhones.contains(phone.id) {
                    Text("Connected", bundle: .module, comment: "An iPhone of the companion.")
                  } else {
                    Text(
                      "Added \(phone.addedAt.formatted(date: .abbreviated, time: .omitted))",
                      bundle: .module, comment: "When an iPhone was first admitted.")
                  }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              Spacer()
              Button {
                removing = phone
              } label: {
                Text("Remove…", bundle: .module, comment: "Removes an iPhone from the companion.")
              }
            }
          }
        } header: {
          Text("iPhones", bundle: .module, comment: "A section of Settings › iPhone Companion.")
        } footer: {
          Text(
            "Only the iPhones of your iCloud account can connect. Remove one you gave away or lost: it can no longer reach this Mac.",
            bundle: .module
          )
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      Text(
        "Remove “\(removing?.name ?? "")”?", bundle: .module,
        comment: "Asks before removing an iPhone from the companion."),
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible
    ) {
      Button(role: .destructive) {
        if let removing { companion.remove(removing) }
        removing = nil
      } label: {
        Text("Remove", bundle: .module, comment: "Removes an iPhone from the companion.")
      }
    } message: {
      Text(
        "It can no longer connect to this Mac. Opening Vibe Companion on it again adds it back.",
        bundle: .module)
    }
  }

  private static let alphaInstructions = URL(
    string: "https://github.com/hadrienl/vibe-manager/blob/main/README.md#iphone-companion-alpha")!
  private static let testFlightInvitation = URL(string: "https://testflight.apple.com/join/DsJgybUh")!

  private var unavailable: String? {
    switch companion.availability {
    case .available: nil
    case .notEmbedded:
      String(
        localized: "This build of Vibe Manager does not include the companion.", bundle: .module)
    case .needsAppleSilicon:
      String(localized: "The iPhone companion needs a Mac with Apple silicon.", bundle: .module)
    }
  }

  private var stateText: String {
    switch companion.state {
    case .off, .starting:
      String(localized: "Starting…", bundle: .module, comment: "The companion's agent.")
    case .running:
      String(
        localized: "Ready: your iPhones can connect", bundle: .module,
        comment: "The companion's agent.")
    case .noAccount:
      String(
        localized: "Sign in to iCloud on this Mac to use the companion", bundle: .module,
        comment: "The companion's agent.")
    case .failed:
      String(
        localized: "The companion could not start", bundle: .module,
        comment: "The companion's agent.")
    }
  }
}
