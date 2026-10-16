import CompanionCore
import SwiftUI

/// Open Quickly, as ⌘P on the Mac (#400): the recent sessions first, then what the Mac's index
/// finds for the text — a ticket, a pull request's URL, a branch, a folder, a title — with why.
struct SearchSheet: View {
  let open: (String) -> Void
  @Environment(RemoteChannel.self) private var channel
  @State private var query = ""

  var body: some View {
    NavigationStack {
      List {
        if query.isEmpty {
          Section("Récentes") {
            ForEach(recent) { session in
              row(session, reason: session.folderName, isArchived: false)
            }
          }
        } else {
          Section {
            ForEach(channel.searchResults) { result in
              if let session = channel.sessions.first(where: { $0.id == result.sessionID }) {
                row(session, reason: result.reason, isArchived: result.isArchived)
              }
            }
          } footer: {
            if channel.searchResults.isEmpty {
              Text("Aucune session ne correspond à « \(query) ».")
            } else {
              Text(
                "Tape un ticket (#36, owner/repo#36), l’adresse d’une pull ou merge request, une branche, un dossier ou un titre."
              )
            }
          }
        }
      }
      .navigationTitle("Ouvrir une session")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(
        text: $query, placement: .navigationBarDrawer(displayMode: .always),
        prompt: "Ticket, PR, branche, dossier, titre")
      .onChange(of: query) { _, text in
        guard !text.isEmpty else { return }
        channel.search(text)
      }
    }
  }

  private var recent: [RemoteSession] {
    Array(
      channel.sessions.filter { $0.status != .archived }
        .sorted { $0.updatedAt > $1.updatedAt }
        .prefix(12))
  }

  private func row(_ session: RemoteSession, reason: String?, isArchived: Bool) -> some View {
    Button {
      open(session.id)
    } label: {
      HStack(spacing: 12) {
        SessionBadge(appearance: session.appearance, activity: session.activity, size: 32)
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text(verbatim: session.name).font(.body.weight(.semibold)).lineLimit(1)
            if isArchived {
              Text("Archivée")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(.tertiarySystemFill), in: Capsule())
            }
          }
          if let reason {
            Text(verbatim: reason).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
    }
    .foregroundStyle(.primary)
  }
}
