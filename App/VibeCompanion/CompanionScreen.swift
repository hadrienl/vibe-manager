import CompanionCore
import CompanionKit
import SwiftUI
import UIKit

/// The connection's diagnostic, reached from the settings (#400) — the trials' debug screen
/// (#347): the state of the Mac, iCloud, the synchronisation, the channel, the test, the journal.
struct CompanionScreen: View {
  @Environment(CompanionModel.self) private var model
  @Environment(CompanionChannel.self) private var channel
  @Environment(CompanionNotifications.self) private var notifications
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Group {
      List {
        if model.macs.count > 1 { macPicker }
        StatusSection()
        ChannelSection()
        cloudSection
        syncSection
        sessionsSection
        TestSection()
        NotificationsSection()
        journalSection
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Connection Diagnostic")
      .refreshable { await model.refresh() }
      // Every ten seconds while the screen is up: a fetch without changes costs one request and
      // sends no push to anyone.
      .task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(10))
          await model.refresh()
          await notifications.refresh()
        }
      }
      .onChange(of: scenePhase) { _, phase in
        switch phase {
        case .active:
          Task {
            await model.refresh()
            await notifications.refresh()
          }
          // Back from the background, where it was closed; already up at launch.
          if channel.phase != .connecting && channel.phase != .connected {
            channel.open(to: model.selectedMac)
          }
        case .background:
          // iOS suspends the application and breaks its socket: the endpoint goes with it.
          channel.close()
        default:
          break
        }
      }
      // A Mac picked, or its endpoint published: dialed at once, in the foreground.
      .onChange(of: model.selectedMac?.irohEndpointID, initial: true) { _, _ in
        if scenePhase == .active { channel.open(to: model.selectedMac) }
      }
    }
  }

  private var macPicker: some View {
    // The Mac shown by default — the one seen last — is the one selected until another is picked.
    let selection = Binding(
      get: { model.selectedMac?.installationID },
      set: { model.selectedMacID = $0 })
    return Section {
      Picker("Mac", selection: selection) {
        ForEach(model.macs, id: \.installationID) { mac in
          Text(verbatim: mac.buildLabel.isEmpty ? mac.name : "\(mac.name) (\(mac.buildLabel))")
            .tag(Optional(mac.installationID))
        }
      }
    }
  }

  private var cloudSection: some View {
    Section("iCloud") {
      LabeledContent("Account", value: Self.label(of: model.status.account))
      LabeledContent("Container") {
        Text(verbatim: CompanionCloud.containerIdentifier)
          .font(.footnote.monospaced())
      }
      LabeledContent(
        "Environment",
        value: Bundle.main.object(forInfoDictionaryKey: "VibeCloudKitEnvironment") as? String
          ?? "?")
    }
  }

  private var syncSection: some View {
    Section("Sync") {
      LabeledContent("Mac Seen") {
        if let mac = model.selectedMac {
          Text("\(Text(mac.lastSeen, style: .relative)) ago")
        } else {
          Text("never")
        }
      }
      LabeledContent("Last Fetch", value: Self.time(model.status.lastFetch))
      LabeledContent("Last Push Received", value: Self.time(model.status.lastPush))
      LabeledContent("Pending Changes", value: "\(model.status.pendingChanges)")
      LabeledContent("Last Error") {
        Text(verbatim: model.status.lastError ?? String(localized: "none"))
          .multilineTextAlignment(.trailing)
          .textSelection(.enabled)
      }
    }
  }

  private var sessionsSection: some View {
    Section {
      if model.visibleSessions.isEmpty {
        Text("No active session").foregroundStyle(.secondary)
      }
      ForEach(model.visibleSessions, id: \.id) { session in
        CloudSessionRow(session: session)
      }
    } header: {
      Text("Active Sessions on the Mac · \(model.visibleSessions.count)")
    } footer: {
      Text("Read only. Updated through CloudKit.")
    }
  }

  private var journalSection: some View {
    Section {
      Text(verbatim: CompanionJournal.text(model.journal))
        .font(.caption2.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Copy Journal") {
        UIPasteboard.general.string = CompanionJournal.text(model.journal)
      }
    } header: {
      Text("Journal")
    }
  }

  static func label(of account: CompanionAccountState) -> String {
    switch account {
    case .unknown: String(localized: "unknown")
    case .available: String(localized: "available")
    case .noAccount: String(localized: "no account")
    case .restricted: String(localized: "restricted")
    case .couldNotDetermine: String(localized: "could not be determined")
    case .temporarilyUnavailable: String(localized: "temporarily unavailable")
    }
  }

  static func time(_ date: Date?) -> String {
    date?.formatted(date: .omitted, time: .standard) ?? String(localized: "never")
  }
}

/// "Mac connecté" or "Mac hors ligne", with the Mac's name and build.
private struct StatusSection: View {
  @Environment(CompanionModel.self) private var model

  var body: some View {
    Section {
      HStack(spacing: 12) {
        Circle()
          .fill(model.isConnected ? Color.green : Color.red)
          .frame(width: 12, height: 12)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(model.isConnected ? "Mac connected" : "Mac offline")
            .font(.headline)
          if let mac = model.selectedMac {
            Text(verbatim: Self.subtitle(of: mac))
              .font(.subheadline)
              .foregroundStyle(.secondary)
          } else {
            Text("No Mac has published yet")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      }
      .accessibilityElement(children: .combine)
    } header: {
      Text("Vibe Companion · Diagnostic")
    }
  }

  static func subtitle(of mac: CompanionMac) -> String {
    let build = mac.buildLabel.isEmpty ? mac.version : "\(mac.version) (\(mac.buildLabel))"
    return "\(mac.name) · Vibe Manager \(build)"
  }
}

private struct CloudSessionRow: View {
  let session: CompanionSession

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: session.title).lineLimit(1)
        Text(verbatim: session.agent).font(.footnote).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Text(label)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.18), in: Capsule())
        .foregroundStyle(tint)
    }
    .accessibilityElement(children: .combine)
  }

  private var label: LocalizedStringKey {
    switch session.state {
    case .needsAttention: "Needs Attention"
    case .working: "Working"
    case .waiting: "Waiting"
    }
  }

  private var tint: Color {
    switch session.state {
    case .needsAttention: .orange
    case .working: .blue
    case .waiting: .secondary
    }
  }
}

/// The button, then each step of the test as it comes back.
private struct TestSection: View {
  @Environment(CompanionModel.self) private var model

  var body: some View {
    Section("Test") {
      Button {
        Task { await model.sendTest() }
      } label: {
        Text("Test")
          .font(.headline)
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(.borderedProminent)
      Button {
        Task { await model.sendNotificationTest() }
      } label: {
        Text("Test Notification in 10 s")
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(.bordered)
      if let run = model.testRun {
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: sentLine(run))
          if let received = run.receivedAt, let oneWay = run.oneWay {
            Text(
              "Received by the Mac at \(CompanionScreen.time(received)) (\(Self.seconds(oneWay)))")
          }
          if let roundTrip = run.roundTrip {
            Text("Acknowledged: round trip \(Self.seconds(roundTrip))")
              .fontWeight(.semibold)
          }
        }
        .font(.subheadline)
      }
    }
  }

  private func sentLine(_ run: CompanionTestRun) -> String {
    let time = CompanionScreen.time(run.sentAt)
    switch run.stage {
    case .sending: return String(localized: "Sending… (written at \(time))")
    case .sent, .acknowledged: return String(localized: "Sent at \(time)")
    }
  }

  static func seconds(_ interval: TimeInterval) -> String {
    interval.formatted(.number.precision(.fractionLength(1))) + " s"
  }
}

/// The notifications of the Mac's requests (#368): whether iOS lets them through, whether CloudKit
/// holds the subscription, and the last one seen.
private struct NotificationsSection: View {
  @Environment(CompanionModel.self) private var model
  @Environment(CompanionNotifications.self) private var notifications

  var body: some View {
    Section {
      LabeledContent("Permission", value: notifications.permission.label)
      LabeledContent(
        "APNs Registration", value: notifications.registration ?? String(localized: "pending"))
      LabeledContent("CloudKit Subscription") {
        Text(verbatim: subscriptionLabel)
          .multilineTextAlignment(.trailing)
          .textSelection(.enabled)
      }
      if let sent = model.notificationTestSentAt {
        LabeledContent("Test Asked At", value: CompanionScreen.time(sent))
      }
      LabeledContent("Last Request from the Mac") {
        if let request = model.latestRequest {
          VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: request.sessionTitle)
            Text(verbatim: "\(request.agent) \(request.text)")
              .font(.footnote)
              .foregroundStyle(.secondary)
            Text(verbatim: CompanionScreen.time(request.createdAt))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        } else {
          Text("none")
        }
      }
      LabeledContent("Last Notification Shown") {
        if let delivery = notifications.lastDelivery {
          VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: delivery.title)
            Text(verbatim: delivery.body).font(.footnote).foregroundStyle(.secondary)
            Text(verbatim: CompanionScreen.time(delivery.date))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        } else {
          Text("none")
        }
      }
    } header: {
      Text("Notifications")
    } footer: {
      Text(
        "The subscription fails until the container’s schema has the Envelope type. It is tried again every 30 s while this screen is open."
      )
    }
  }

  private var subscriptionLabel: String {
    switch notifications.subscription {
    case .notSaved: String(localized: "not yet")
    case .saving: String(localized: "saving…")
    case .saved: String(localized: "saved (\(CompanionRequestAlerts.subscriptionID))")
    case .failed(let error): String(localized: "failed: \(error)")
    }
  }
}

#Preview {
  NavigationStack { CompanionScreen() }
    .environment(CompanionModel(sync: PreviewCompanionSync(), deviceName: "iPhone"))
    .environment(CompanionChannel())
    .environment(CompanionNotifications())
}

/// A synchronisation that only answers with fixed records, for the preview.
private final class PreviewCompanionSync: CompanionSyncing, @unchecked Sendable {
  func start(onUpdate: @escaping @Sendable (CompanionSyncUpdate) -> Void) async {
    let now = Date()
    let records: [CompanionRecord] = [
      .mac(
        CompanionMac(
          installationID: "A", name: "MacBook Pro", version: "1.0.2", buildLabel: "#347",
          online: true, lastSeen: now)),
      .session(
        CompanionSession(
          id: "1", macID: "A", title: "#347 Compagnon mobile", agent: "Claude Code",
          state: .needsAttention, updatedAt: now)),
      .session(
        CompanionSession(
          id: "2", macID: "A", title: "Barre d’outils transparente", agent: "Codex",
          state: .working, updatedAt: now)),
    ]
    onUpdate(CompanionSyncUpdate(records: records, status: CompanionSyncStatus(), journal: []))
  }

  func fetchChanges() async { /* The preview has no iCloud: nothing to do. */ }
  func sendChanges() async { /* The preview has no iCloud: nothing to do. */ }
  func save(_: [CompanionRecord]) async { /* The preview has no iCloud: nothing to do. */ }
  func delete(_: [String]) async { /* The preview has no iCloud: nothing to do. */ }
  func notePush() async { /* The preview has no iCloud: nothing to do. */ }
  func note(_: String) async { /* The preview has no iCloud: nothing to do. */ }
  func refreshAccountStatus() async { /* The preview has no iCloud: nothing to do. */ }
}
