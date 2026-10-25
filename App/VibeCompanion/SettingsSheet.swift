import CompanionCore
import CompanionKit
import SwiftUI

/// The settings (#400): which Mac, how it is reached, the notifications, and the connection's
/// diagnostic — the trials' debug screen.
struct SettingsSheet: View {
  @Environment(CompanionModel.self) private var model
  @Environment(RemoteChannel.self) private var channel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Form {
        Section {
          if model.macs.isEmpty {
            Text("No Mac has published itself yet.").foregroundStyle(.secondary)
          }
          ForEach(model.macs, id: \.installationID) { mac in
            Button {
              model.selectedMacID = mac.installationID
            } label: {
              HStack(spacing: 12) {
                Image(
                  systemName: model.selectedMac?.installationID == mac.installationID
                    ? "checkmark.circle.fill" : "circle"
                )
                .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                  Text(verbatim: mac.name).foregroundStyle(.primary)
                  Text(verbatim: state(of: mac)).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Text(verbatim: mac.buildLabel.isEmpty ? mac.version : mac.buildLabel)
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              }
            }
          }
        } header: {
          Text("Mac")
        } footer: {
          Text(
            "The Macs of your iCloud account where Vibe Manager runs the companion. There’s nothing else to pair."
          )
        }
        Section("Notifications") {
          Button("Notification Settings") {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
              // Opens outside: iOS's own settings page for this app, a fixed system address.
              openURL(url)
            }
          }
        }
        Section("About") {
          LabeledContent("Version", value: Self.version)
          NavigationLink("Connection Diagnostic") {
            CompanionScreen()
          }
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("OK", systemImage: "checkmark") { dismiss() }
        }
      }
    }
  }

  private func state(of mac: CompanionMac) -> String {
    let isSelected = model.selectedMac?.installationID == mac.installationID
    if isSelected, channel.phase == .connected {
      switch channel.path {
      case .direct: return String(localized: "Connected · direct")
      case .relay: return String(localized: "Connected · through a relay")
      default: return String(localized: "Connected")
      }
    }
    let seen = mac.lastSeen.formatted(.relative(presentation: .named))
    if Date().timeIntervalSince(mac.lastSeen) < 120, mac.online {
      return String(localized: "Online · seen \(seen)")
    }
    return mac.online
      ? String(localized: "Asleep · seen \(seen)") : String(localized: "Offline · seen \(seen)")
  }

  private static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }
}
