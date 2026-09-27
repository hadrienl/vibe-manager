import SwiftUI
import VibeApplication
import VibeDomain

/// Where the titles of a new session's tickets stand, above its notes (#89): in words, discreetly,
/// never in an alert. Nothing is shown once every line is in the notes.
struct TicketTitlesStatusView: View {
  let sessionID: SessionID
  let model: TicketTitlesModel

  var body: some View {
    let entries = (model.entries[sessionID] ?? []).filter { TicketTitlesPresentation.isShown($0) }
    if !entries.isEmpty {
      VStack(alignment: .leading, spacing: 3) {
        ForEach(entries) { entry in
          row(entry)
        }
        if entries.contains(where: { TicketTitlesPresentation.canRetry($0) }) {
          Button {
            model.retry(sessionID)
          } label: {
            Text("Try Again", bundle: .module, comment: "Reads the tickets' pages again.")
          }
          .buttonStyle(.link)
          .font(.caption)
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, 4)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("ticket-titles-status")
    }
  }

  private func row(_ entry: TicketTitlesModel.Entry) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: TicketTitlesPresentation.symbol(entry.state))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(TicketTitlesPresentation.sentence(entry))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if TicketTitlesPresentation.offersTab(entry.state) {
        Button {
          model.showTicket(entry, in: sessionID)
        } label: {
          Text("Show Tab", bundle: .module, comment: "Shows the web view's tab of a ticket.")
        }
        .buttonStyle(.link)
      }
    }
    .font(.caption)
  }
}

/// The words for where a ticket stands.
enum TicketTitlesPresentation {
  static func isShown(_ entry: TicketTitlesModel.Entry) -> Bool {
    switch entry.state {
    case .waiting, .inserted, .alreadyInNotes: return false
    default: return true
    }
  }

  /// A page waiting for the user: a sign-in page, or a ticket not visible to whoever is signed in.
  static func offersTab(_ state: TicketTitlesModel.State) -> Bool {
    switch state {
    case .signInRequired, .notFound: return true
    default: return false
    }
  }

  static func canRetry(_ entry: TicketTitlesModel.Entry) -> Bool {
    !entry.state.isSettled && !entry.state.isUnderWay
  }

  static func symbol(_ state: TicketTitlesModel.State) -> String {
    switch state {
    case .waiting, .reading: return "arrow.down.circle"
    case .signInRequired: return "person.crop.circle.badge.exclamationmark"
    case .inserted, .alreadyInNotes: return "checkmark.circle"
    default: return "exclamationmark.circle"
    }
  }

  static func sentence(_ entry: TicketTitlesModel.Entry) -> String {
    let id = entry.ticket.shortID
    switch entry.state {
    case .waiting, .reading:
      return String(
        localized: "Reading the title of \(id)…", bundle: .module,
        comment: "A ticket's identifier: “acme/app#42”, “PROJ-123”.")
    case .signInRequired(let host):
      return String(
        localized: "Sign in to \(host) in the web view to read the title of \(id).",
        bundle: .module, comment: "A site, then a ticket's identifier.")
    case .inserted, .alreadyInNotes:
      return String(
        localized: "The title of \(id) is in the notes.", bundle: .module,
        comment: "A ticket's identifier.")
    case .notFound:
      return String(
        localized: "\(id) was not found, or is visible only once signed in: sign in in its tab.",
        bundle: .module, comment: "A ticket's identifier.")
    case .failed(let failure):
      return failed(failure, id: id)
    case .notesFull:
      return String(
        localized: "The title of \(id) does not fit in the notes.", bundle: .module,
        comment: "A ticket's identifier.")
    case .notesUnreadable:
      return String(
        localized: "The title of \(id) was not added: the notes could not be read.",
        bundle: .module, comment: "A ticket's identifier.")
    case .interrupted:
      return String(
        localized: "The title of \(id) was not read: its tab was closed.", bundle: .module,
        comment: "A ticket's identifier.")
    }
  }

  static func failed(_ failure: TicketPageFailure, id: String) -> String {
    switch failure {
    case .http(let status):
      return String(
        localized: "The page of \(id) answered with the error \(String(status)).",
        bundle: .module, comment: "A ticket's identifier, then an HTTP status: “500”.")
    case .offline:
      return String(
        localized: "The title of \(id) was not read: the Mac is offline.", bundle: .module,
        comment: "A ticket's identifier.")
    case .unreachable(let host):
      return String(
        localized: "The title of \(id) was not read: \(host) cannot be reached.",
        bundle: .module, comment: "A ticket's identifier, then a site.")
    case .untrustedCertificate(let host):
      return String(
        localized: "The title of \(id) was not read: the certificate of \(host) is not trusted.",
        bundle: .module, comment: "A ticket's identifier, then a site.")
    case .load(let reason):
      return String(
        localized: "The title of \(id) was not read: \(reason)", bundle: .module,
        comment: "A ticket's identifier, then the reason WebKit gave.")
    case .noTitle:
      return String(
        localized: "The page of \(id) gave no title.", bundle: .module,
        comment: "A ticket's identifier.")
    case .timedOut:
      return String(
        localized: "The page of \(id) did not load in time.", bundle: .module,
        comment: "A ticket's identifier.")
    }
  }
}
