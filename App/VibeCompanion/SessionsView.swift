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
  /// The form shown, which comes back with the creation that failed.
  @State private var newSessionForm: NewSessionForm?
  /// The folders folded away, by path.
  @State private var collapsed: Set<String> = []
  /// The coordinators whose done children show.
  @State private var showingDone: Set<String> = []
  /// The coordinators whose children are folded away, by a long press on their row.
  @State private var foldedCoordinators: Set<String> = []
  @State private var foldTicks = 0

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Section {
          Picker("Status", selection: $filter) {
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
          Section(isExpanded: expansion(of: group.path)) {
            ForEach(group.rows) { row in
              rowView(row)
                .background {
                  if let line = row.line { FamilyLineView(line: line) }
                }
                // The line runs from row to row: no separator across it.
                .listRowSeparator(row.line == nil ? .automatic : .hidden)
            }
          } header: {
            FolderHeader(name: group.name, isExpanded: expansion(of: group.path))
          }
        }
        if channel.phase == .connected, groups.isEmpty {
          Text("Nothing in \(Text(filter.label).foregroundStyle(.secondary))")
            .foregroundStyle(.secondary)
        }
      }
      .listStyle(.insetGrouped)
      .sensoryFeedback(.impact, trigger: foldTicks)
      .navigationTitle("Vibe Manager")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Settings", systemImage: "gearshape") { showsSettings = true }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("New Session", systemImage: "plus") { newSessionForm = NewSessionForm() }
            .disabled(channel.phase != .connected || channel.pendingCreation != nil)
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
        .accessibilityLabel("Search the Sessions")
        .padding(20)
      }
      .navigationDestination(for: String.self) { id in
        if id == CreatingSessionView.id {
          CreatingSessionView()
        } else {
          ConversationView(sessionID: id)
        }
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
      .sheet(item: $newSessionForm) { form in
        NewSessionSheet(returned: form.returned)
      }
      .onChange(of: channel.pendingCreation != nil) { _, isCreating in
        if isCreating { path.append(CreatingSessionView.id) }
      }
      .onChange(of: channel.returnedCreation) { _, returned in
        guard let returned else { return }
        channel.returnedCreation = nil
        path.removeAll { $0 == CreatingSessionView.id }
        showsSearch = false
        showsSettings = false
        newSessionForm = NewSessionForm(returned: returned)
      }
      .onChange(of: channel.notifiedSessionID, initial: true) { _, id in
        guard let id else { return }
        channel.notifiedSessionID = nil
        showsSearch = false
        showsSettings = false
        newSessionForm = nil
        path = [id]
      }
      .onChange(of: channel.createdSessionID) { _, id in
        guard let id else { return }
        channel.createdSessionID = nil
        // Someone who left the waiting screen, or cancelled the form, is not taken back; a form
        // opened for another session stays.
        let isReturned = newSessionForm?.returned != nil
        let isWaiting = path.contains(CreatingSessionView.id) || isReturned
        if isReturned { newSessionForm = nil }
        var shown = path.filter { $0 != CreatingSessionView.id }
        if isWaiting { shown.append(id) }
        path = shown
      }
    }
  }

  private func expansion(of folder: String) -> Binding<Bool> {
    Binding(
      get: { !collapsed.contains(folder) },
      set: { expanded in
        if expanded { collapsed.remove(folder) } else { collapsed.insert(folder) }
      })
  }

  @ViewBuilder private func rowView(_ row: RemoteSessionRow) -> some View {
    switch row.content {
    case .session(let session, let ownStatus):
      // Gestures rather than a Button: a Button also opens the session when a long press ends.
      let canFold = row.line == .parent || row.foldedChildren > 0
      SessionRow(
        session: session, indented: row.isChild, ownStatus: ownStatus,
        foldedChildren: row.foldedChildren
      )
      .contentShape(Rectangle())
      .onTapGesture { path.append(session.id) }
      .onLongPressGesture {
        if canFold { toggleFold(of: session.id) }
      }
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { path.append(session.id) }
      .accessibilityActions {
        if canFold {
          Button(row.foldedChildren > 0 ? "Show Children" : "Hide Children") {
            toggleFold(of: session.id)
          }
        }
      }
      .statusSwipe(of: session) { channel.setStatus($0, of: session.id) }
    case .doneChildren(let coordinatorID, let count, let isShown):
      DoneChildrenRow(count: count, isShown: isShown) {
        withAnimation {
          if isShown {
            showingDone.remove(coordinatorID)
          } else {
            showingDone.insert(coordinatorID)
          }
        }
      }
    }
  }

  private func toggleFold(of id: String) {
    foldTicks += 1
    withAnimation {
      if foldedCoordinators.contains(id) {
        foldedCoordinators.remove(id)
      } else {
        foldedCoordinators.insert(id)
      }
    }
  }

  private var families: RemoteSessionFamilies { RemoteSessionFamilies(channel.sessions) }

  private func count(_ status: RemoteTaskStatus) -> Int {
    families.count(in: status)
  }

  private var groups: [RemoteSessionGroup] {
    families.groups(in: filter, showingDone: showingDone, folded: foldedCoordinators)
  }
}

/// “Show Done Sessions (3)” under a coordinator's children, as on the Mac (#468).
struct DoneChildrenRow: View {
  let count: Int
  let isShown: Bool
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 6) {
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .rotationEffect(.degrees(isShown ? 180 : 0))
        if isShown {
          Text("Hide Done Sessions")
        } else {
          Text("Show Done Sessions (\(count))")
        }
        Spacer(minLength: 0)
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.leading, FamilyLineGeometry.childIndent)
  }
}

/// A row's piece of the line that ties a coordinator to its children, behind it (#468). Opaque:
/// where the pieces of two rows meet, they do not darken each other.
struct FamilyLineView: View {
  let line: RemoteFamilyLine

  var body: some View {
    GeometryReader { proxy in
      Path { path in
        let geometry = FamilyLineGeometry.self
        let middle = proxy.size.height / 2
        switch line {
        case .parent:
          path.move(to: CGPoint(x: geometry.x, y: middle + geometry.badgeSize / 2 + geometry.gap))
          path.addLine(to: CGPoint(x: geometry.x, y: proxy.size.height + geometry.overrun))
        case .child(let isLast):
          path.move(to: CGPoint(x: geometry.x, y: -geometry.overrun))
          path.addLine(
            to: CGPoint(
              x: geometry.x, y: isLast ? middle : proxy.size.height + geometry.overrun))
          path.move(to: CGPoint(x: geometry.x, y: middle))
          path.addLine(to: CGPoint(x: geometry.childIndent - geometry.gap, y: middle))
        }
      }
      .stroke(Color(.systemGray4), lineWidth: 1.5)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Where the line runs, the badges set as `SessionRow` sets them.
enum FamilyLineGeometry {
  static let badgeSize: CGFloat = 34
  /// Under the middle of the coordinator's badge.
  static var x: CGFloat { badgeSize / 2 }
  /// How far a child's badge is set in: room for the elbow.
  static let childIndent: CGFloat = 28
  static let gap: CGFloat = 3
  /// Past the insets of the list's cells, to meet the next row's piece.
  static let overrun: CGFloat = 20
}

/// One showing of the new session form.
struct NewSessionForm: Identifiable {
  let id = UUID()
  var returned: ReturnedCreation?
}

/// A session being created (#470), until the Mac says it exists.
struct CreatingSessionView: View {
  /// Its place in the navigation path, which no session of the Mac has: those are UUIDs.
  static let id = "creating"
  @Environment(RemoteChannel.self) private var channel

  private var title: String {
    guard let request = channel.pendingCreation else { return "" }
    return request.name.isEmpty ? (request.folder as NSString).lastPathComponent : request.name
  }

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Creating the Session…").foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle(Text(verbatim: title))
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// A folder's header, which folds its sessions away: the whole line, as Mail's mailboxes.
struct FolderHeader: View {
  let name: String
  @Binding var isExpanded: Bool

  var body: some View {
    Button {
      withAnimation { isExpanded.toggle() }
    } label: {
      HStack {
        Label(name, systemImage: "folder")
        Spacer()
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(Text(isExpanded ? "Expanded" : "Collapsed"))
  }
}

struct SessionRow: View {
  let session: RemoteSession
  var indented = false
  /// A child's own status, when it is listed in another column.
  var ownStatus: RemoteTaskStatus?
  /// How many children a folded coordinator hides.
  var foldedChildren = 0

  var body: some View {
    HStack(spacing: 12) {
      SessionBadge(
        appearance: session.appearance, activity: session.activity,
        size: FamilyLineGeometry.badgeSize)
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(verbatim: session.name)
            .font(.body.weight(.semibold))
            .lineLimit(1)
          Spacer(minLength: 8)
          if session.isCoordinator {
            Label("Coordinator", systemImage: "person.3")
              .labelStyle(.iconOnly)
              .foregroundStyle(.tint)
          }
          if foldedChildren > 0 {
            HStack(spacing: 2) {
              Text(verbatim: "\(foldedChildren)")
              Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Text(verbatim: ShortDate.text(session.updatedAt))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        HStack(spacing: 4) {
          Text(verbatim: session.subtitle)
            .foregroundStyle(session.activity == .needsAttention ? Color.orange : .secondary)
          if let ownStatus {
            Text(verbatim: "·")
            Text(ownStatus.label)
              .layoutPriority(1)
          }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
    }
    .padding(.leading, indented ? FamilyLineGeometry.childIndent : 0)
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
            Button("Try Again") { channel.open(to: model.selectedMac) }
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
        symbol: "", tint: .blue, title: "Connecting to \(name)…",
        detail: String(localized: "The list stays as it was."))
    case .idle, .noMac, .failed:
      guard let mac else {
        return Banner(
          symbol: "desktopcomputer", tint: .secondary, title: "No Mac",
          detail: String(
            localized:
              "On your Mac, turn on Vibe Manager › Settings › iPhone Companion, with the same iCloud account as this iPhone."
          ))
      }
      if !model.isConnected {
        let seen = mac.lastSeen.formatted(.relative(presentation: .named))
        return mac.online
          ? Banner(
            symbol: "moon.zzz", tint: .indigo, title: "\(name) Is Asleep",
            detail: String(localized: "Seen \(seen). The sessions go on when it wakes up."))
          : Banner(
            symbol: "desktopcomputer.trianglebadge.exclamationmark", tint: .red,
            title: "\(name) Is Offline",
            detail: String(
              localized:
                "Seen \(seen). Open Vibe Manager on the Mac, with Settings › iPhone Companion turned on."
            ))
      }
      if case .failed(let reason) = channel.phase {
        return Banner(
          symbol: "bolt.horizontal.circle", tint: .orange, title: "Can’t Reach the Mac",
          detail: reason)
      }
      return Banner(
        symbol: "bolt.horizontal.circle", tint: .orange, title: "Not Connected Yet",
        detail: String(localized: "The Mac hasn’t published its address."))
    }
  }
}

/// When a session last moved, as Mail and Messages say it in their lists: “now”, “3 min”,
/// “14:32”, “Yesterday”, “Monday”, “Oct 12”.
enum ShortDate {
  static func text(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return String(localized: "now") }
    if seconds < 3600 { return String(localized: "\(Int(seconds / 60)) min") }
    if calendar.isDate(date, inSameDayAs: now) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
    if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
      return date.formatted(.dateTime.weekday(.wide))
    }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      return date.formatted(.dateTime.day().month(.abbreviated))
    }
    return date.formatted(date: .numeric, time: .omitted)
  }
}
