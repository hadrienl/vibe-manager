import CompanionCore
import CompanionKit
import SwiftUI

/// The Mac's sessions, as its sidebar lists them (#400): the four columns, the folders, the
/// coordinators and their sessions, a swipe to move one to another column.
struct SessionsView: View {
  @Environment(RemoteChannel.self) private var channel
  @Environment(CompanionModel.self) private var model
  @State private var filter = RemoteTaskStatus.doing
  @State private var path: [String] = []
  @State private var showsSearch = false
  @State private var showsSettings = false
  @State private var showsNewSession = false
  /// The row whose swipe buttons are open: one at a time.
  @State private var swipedID: String?

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Section {
          Picker("Statut", selection: $filter) {
            ForEach(RemoteTaskStatus.columns, id: \.self) { status in
              Text("\(Text(status.label)) \(count(status))").tag(status)
            }
          }
          .pickerStyle(.segmented)
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
        }
        ConnectionBanner()
        ForEach(groups, id: \.path) { group in
          Section {
            ForEach(group.rows) { row in
              StatusSwipe(
                id: row.session.id, leading: row.session.status.previous,
                trailing: row.session.status.next, openID: $swipedID,
                choose: { channel.setStatus($0, of: row.session.id) },
                tap: { path.append(row.session.id) }
              ) {
                SessionRow(session: row.session, indented: row.indented)
                  .padding(.horizontal, 16)
                  .padding(.vertical, 10)
                  .background(Color(.secondarySystemGroupedBackground))
              }
              .listRowInsets(EdgeInsets())
            }
          } header: {
            Label(group.name, systemImage: "folder")
          }
        }
        if channel.phase == .connected, groups.isEmpty {
          Text("Aucune session \(Text(filter.label).foregroundStyle(.secondary))")
            .foregroundStyle(.secondary)
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Vibe Manager")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Réglages", systemImage: "gearshape") { showsSettings = true }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Nouvelle session", systemImage: "plus") { showsNewSession = true }
            .disabled(channel.phase != .connected)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        Button {
          showsSearch = true
        } label: {
          Image(systemName: "magnifyingglass")
            .font(.title2.weight(.semibold))
            .frame(width: 56, height: 56)
        }
        .buttonStyle(.glass)
        .clipShape(Circle())
        .accessibilityLabel("Rechercher dans les sessions")
        .padding(20)
      }
      .navigationDestination(for: String.self) { id in
        ConversationView(sessionID: id)
      }
      .sheet(isPresented: $showsSearch) {
        SearchSheet { id in
          showsSearch = false
          path.append(id)
        }
        .presentationDetents([.medium, .large])
      }
      .sheet(isPresented: $showsSettings) {
        SettingsSheet()
      }
      .sheet(isPresented: $showsNewSession) {
        NewSessionSheet()
      }
      .onChange(of: channel.createdSessionID) { _, id in
        guard let id else { return }
        channel.createdSessionID = nil
        showsNewSession = false
        path.append(id)
      }
    }
  }

  private func count(_ status: RemoteTaskStatus) -> Int {
    channel.sessions.filter { $0.status == status }.count
  }

  // MARK: - Grouping

  struct Row: Identifiable {
    var id: String { session.id }
    let session: RemoteSession
    let indented: Bool
  }

  struct Group {
    let path: String
    let name: String
    let rows: [Row]
  }

  /// The sessions of the column, by folder, each coordinator followed by its own sessions; a
  /// session whose coordinator is in another column stands alone.
  private var groups: [Group] {
    let shown = channel.sessions.filter { $0.status == filter }
    let shownIDs = Set(shown.map(\.id))
    let byRank: (RemoteSession, RemoteSession) -> Bool = {
      ($0.rank, $0.updatedAt) < ($1.rank, $1.updatedAt)
    }
    let children = Dictionary(
      grouping: shown.filter { $0.coordinatorID.map(shownIDs.contains) ?? false },
      by: { $0.coordinatorID ?? "" })
    let tops = shown.filter { !($0.coordinatorID.map(shownIDs.contains) ?? false) }
    let folders = Dictionary(grouping: tops, by: \.folderPath)
    return folders.keys.sorted {
      (folders[$0]?.first?.folderName ?? "").localizedStandardCompare(
        folders[$1]?.first?.folderName ?? "") == .orderedAscending
    }.map { path in
      let sessions = (folders[path] ?? []).sorted(by: byRank)
      var rows: [Row] = []
      for session in sessions {
        rows.append(Row(session: session, indented: false))
        for child in (children[session.id] ?? []).sorted(by: byRank) {
          rows.append(Row(session: child, indented: true))
        }
      }
      return Group(path: path, name: sessions.first?.folderName ?? path, rows: rows)
    }
  }
}

struct SessionRow: View {
  let session: RemoteSession
  var indented = false

  var body: some View {
    HStack(spacing: 12) {
      SessionBadge(
        appearance: session.appearance, activity: session.activity, size: indented ? 28 : 34)
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(verbatim: session.name)
            .font(indented ? .subheadline.weight(.semibold) : .body.weight(.semibold))
            .lineLimit(1)
          Spacer(minLength: 8)
          if session.isCoordinator {
            Label("coordonne", systemImage: "person.3")
              .labelStyle(.iconOnly)
              .foregroundStyle(.tint)
          }
          Text(verbatim: ShortDate.text(session.updatedAt))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(verbatim: session.subtitle)
          .font(.subheadline)
          .foregroundStyle(session.activity == .needsAttention ? Color.orange : .secondary)
          .lineLimit(1)
      }
    }
    .padding(.leading, indented ? 22 : 0)
    .accessibilityElement(children: .combine)
  }
}

/// What stands between the user and the Mac, above the list: nothing once connected.
struct ConnectionBanner: View {
  @Environment(RemoteChannel.self) private var channel
  @Environment(CompanionModel.self) private var model

  var body: some View {
    if let banner {
      Section {
        HStack(spacing: 12) {
          if channel.phase == .connecting {
            ProgressView()
          } else {
            Image(systemName: banner.symbol)
              .font(.title3)
              .foregroundStyle(banner.tint)
          }
          VStack(alignment: .leading, spacing: 2) {
            Text(banner.title).font(.subheadline.weight(.semibold))
            Text(banner.detail).font(.footnote).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          if case .failed = channel.phase {
            Button("Réessayer") { channel.open(to: model.selectedMac) }
              .buttonStyle(.glass)
          }
        }
      }
    }
  }

  private struct Banner {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let detail: String
  }

  private var banner: Banner? {
    let mac = model.selectedMac
    let name = channel.macName ?? mac?.name ?? "Mac"
    switch channel.phase {
    case .connected:
      return nil
    case .connecting:
      return Banner(
        symbol: "", tint: .blue, title: "Connexion à \(name)…",
        detail: "La liste reste visible telle qu’elle était.")
    case .idle, .noMac, .failed:
      guard let mac else {
        return Banner(
          symbol: "desktopcomputer", tint: .secondary, title: "Aucun Mac",
          detail: "Ouvre Vibe Manager sur ton Mac, avec le même compte iCloud.")
      }
      if !model.isConnected {
        let seen = mac.lastSeen.formatted(.relative(presentation: .named))
        return mac.online
          ? Banner(
            symbol: "moon.zzz", tint: .indigo, title: "\(name) en veille",
            detail: "Vu \(seen). Les sessions reprendront à son réveil.")
          : Banner(
            symbol: "desktopcomputer.trianglebadge.exclamationmark", tint: .red,
            title: "\(name) hors ligne",
            detail: "Vibe Manager a été quitté \(seen). Ouvre-le sur le Mac.")
      }
      if case .failed(let reason) = channel.phase {
        return Banner(
          symbol: "bolt.horizontal.circle", tint: .orange, title: "Liaison impossible",
          detail: reason)
      }
      return Banner(
        symbol: "bolt.horizontal.circle", tint: .orange, title: "Pas encore de liaison",
        detail: "Le Mac n’a pas publié son adresse.")
    }
  }
}

/// When a session last moved, as Mail and Messages say it in their lists: « à l’instant »,
/// « 3 min », « 14:32 », « Hier », « lundi », « 12 oct. ».
enum ShortDate {
  static func text(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return String(localized: "à l’instant") }
    if seconds < 3600 { return String(localized: "\(Int(seconds / 60)) min") }
    if calendar.isDate(date, inSameDayAs: now) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    if calendar.isDateInYesterday(date) { return String(localized: "Hier") }
    if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
      return date.formatted(.dateTime.weekday(.wide))
    }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      return date.formatted(.dateTime.day().month(.abbreviated))
    }
    return date.formatted(date: .numeric, time: .omitted)
  }
}
