import CompanionCore
import CompanionKit
import SwiftUI
import UIKit

/// The one screen of the debug application, in sections (#347 mock-up): the state of the Mac,
/// iCloud, the synchronisation, the active sessions, the test, the journal.
struct CompanionScreen: View {
  @Environment(CompanionModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      List {
        if model.macs.count > 1 { macPicker }
        StatusSection()
        cloudSection
        syncSection
        sessionsSection
        TestSection()
        journalSection
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Connexion au Mac")
      .refreshable { await model.refresh() }
      // Every ten seconds while the screen is up: a fetch without changes costs one request and
      // sends no push to anyone.
      .task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(10))
          await model.refresh()
        }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { Task { await model.refresh() } }
      }
    }
  }

  private var macPicker: some View {
    @Bindable var model = model
    return Section {
      Picker("Mac", selection: $model.selectedMacID) {
        ForEach(model.macs, id: \.installationID) { mac in
          Text(verbatim: mac.buildLabel.isEmpty ? mac.name : "\(mac.name) (\(mac.buildLabel))")
            .tag(Optional(mac.installationID))
        }
      }
    }
  }

  private var cloudSection: some View {
    Section("iCloud") {
      LabeledContent("Compte", value: model.status.account.label)
      LabeledContent("Conteneur") {
        Text(verbatim: CompanionCloud.containerIdentifier)
          .font(.footnote.monospaced())
      }
      LabeledContent(
        "Environnement",
        value: Bundle.main.object(forInfoDictionaryKey: "VibeCloudKitEnvironment") as? String
          ?? "?")
    }
  }

  private var syncSection: some View {
    Section("Synchronisation") {
      LabeledContent("Mac vu") {
        if let mac = model.selectedMac {
          Text("il y a \(Text(mac.lastSeen, style: .relative))")
        } else {
          Text("jamais")
        }
      }
      LabeledContent("Dernière récupération", value: Self.time(model.status.lastFetch))
      LabeledContent("Dernier push reçu", value: Self.time(model.status.lastPush))
      LabeledContent("Changements en attente", value: "\(model.status.pendingChanges)")
      LabeledContent("Dernière erreur") {
        Text(verbatim: model.status.lastError ?? "aucune")
          .multilineTextAlignment(.trailing)
          .textSelection(.enabled)
      }
    }
  }

  private var sessionsSection: some View {
    Section {
      if model.visibleSessions.isEmpty {
        Text("Aucune session active").foregroundStyle(.secondary)
      }
      ForEach(model.visibleSessions, id: \.id) { session in
        SessionRow(session: session)
      }
    } header: {
      Text("Sessions actives sur le Mac · \(model.visibleSessions.count)")
    } footer: {
      Text("Lecture seule. Mis à jour par CloudKit.")
    }
  }

  private var journalSection: some View {
    Section {
      Text(verbatim: CompanionJournal.text(model.journal))
        .font(.caption2.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Copier le journal") {
        UIPasteboard.general.string = CompanionJournal.text(model.journal)
      }
    } header: {
      Text("Journal")
    }
  }

  static func time(_ date: Date?) -> String {
    date?.formatted(date: .omitted, time: .standard) ?? "jamais"
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
          Text(model.isConnected ? "Mac connecté" : "Mac hors ligne")
            .font(.headline)
          if let mac = model.selectedMac {
            Text(verbatim: Self.subtitle(of: mac))
              .font(.subheadline)
              .foregroundStyle(.secondary)
          } else {
            Text("Aucun Mac n’a encore publié")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      }
      .accessibilityElement(children: .combine)
    } header: {
      Text("Vibe Companion · debug")
    }
  }

  static func subtitle(of mac: CompanionMac) -> String {
    let build = mac.buildLabel.isEmpty ? mac.version : "\(mac.version) (\(mac.buildLabel))"
    return "\(mac.name) · Vibe Manager \(build)"
  }
}

private struct SessionRow: View {
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
    case .needsAttention: "Besoin d’attention"
    case .working: "Au travail"
    case .waiting: "En attente"
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
      if let run = model.testRun {
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: sentLine(run))
          if let received = run.receivedAt, let oneWay = run.oneWay {
            Text(
              verbatim:
                "Reçu par le Mac à \(CompanionScreen.time(received)) (\(Self.seconds(oneWay)))")
          }
          if let roundTrip = run.roundTrip {
            Text(verbatim: "Accusé de réception : aller-retour \(Self.seconds(roundTrip))")
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
    case .sending: return "Envoi… (écrit à \(time))"
    case .sent, .acknowledged: return "Envoyé à \(time)"
    }
  }

  static func seconds(_ interval: TimeInterval) -> String {
    interval.formatted(.number.precision(.fractionLength(1))) + " s"
  }
}

#Preview {
  CompanionScreen()
    .environment(CompanionModel(sync: PreviewCompanionSync(), deviceName: "iPhone"))
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

  func fetchChanges() async {}
  func sendChanges() async {}
  func save(_ records: [CompanionRecord]) async {}
  func delete(_ recordNames: [String]) async {}
  func notePush() async {}
  func note(_ text: String) async {}
  func refreshAccountStatus() async {}
}
