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
  @State private var showsStillConnected = false

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
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              if canRemove(mac) {
                Button("Remove", systemImage: "trash", role: .destructive) { remove(mac) }
              } else {
                // Gray rather than `.disabled`, which would take the explanation with the touch.
                Button("Remove", systemImage: "trash") { showsStillConnected = true }
                  .tint(.gray)
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
      .alert("This Mac Is Still Connected", isPresented: $showsStillConnected) {
      } message: {
        Text(
          "Vibe Manager is running on this Mac and would put it back in the list. Quit it there first. If it has already stopped, try again in a while."
        )
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

  /// `model.now`, not `Date()`: the clock that redraws the sheet, so that a Mac past the tolerance
  /// turns removable while it is open.
  private func canRemove(_ mac: CompanionMac) -> Bool {
    CompanionMacRemoval.isAllowed(mac, isChannelUp: isChannelUp(to: mac), now: model.now)
  }

  private func isChannelUp(to mac: CompanionMac) -> Bool {
    model.selectedMac?.installationID == mac.installationID && channel.phase == .connected
  }

  private func remove(_ mac: CompanionMac) {
    if model.selectedMac?.installationID == mac.installationID { channel.forgetMac() }
    Task { await model.remove(mac) }
  }

  private func state(of mac: CompanionMac) -> String {
    if isChannelUp(to: mac) {
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
