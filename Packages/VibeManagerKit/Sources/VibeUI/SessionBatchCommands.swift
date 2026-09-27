import SwiftUI
import VibeApplication
import VibeDomain

/// The sidebar's menu for the rows a right click reached (#77): the menu of one session, or the
/// commands on several.
struct SessionSelectionMenu: View {
  let model: AppModel
  let ids: Set<SessionID>

  var body: some View {
    if ids.count == 1, let id = ids.first,
      let session = model.sessions.first(where: { $0.id == id })
    {
      SessionCommandButtons(commands: SessionCommands(model: model, session: session))
    } else if ids.count > 1 {
      SessionBatchCommandButtons(model: model, ids: ordered)
    }
  }

  /// In the order the sidebar draws them, which is the order the commands go through them.
  private var ordered: [SessionID] {
    let drawn = model.displayedSessions.map(\.id).filter { ids.contains($0) }
    return drawn + ids.filter { !drawn.contains($0) }
  }
}

/// A command per action that applies to at least one of the sessions, each saying how many.
struct SessionBatchCommandButtons: View {
  let model: AppModel
  let ids: [SessionID]
  /// Off where only buttons are allowed: a list of accessibility actions has no submenu.
  var includesStatus = true

  var body: some View {
    if includesStatus {
      let moves = SessionTaskStatus.columns
        .map { model.batchPlan(.move(to: $0), for: ids) }
        .filter { !$0.isEmpty }
      if !moves.isEmpty {
        Menu {
          ForEach(moves, id: \.action) { plan in
            Button(model.batchTitle(for: plan)) { request(plan) }
          }
        } label: {
          Text(
            "Status", bundle: .module, comment: "The submenu that moves a session between columns.")
        }
        Divider()
      }
    }
    ForEach(Self.actions, id: \.self) { action in
      let plan = model.batchPlan(action, for: ids)
      if !plan.isEmpty {
        Button(model.batchTitle(for: plan)) { request(plan) }
      }
    }
  }

  static let actions: [SessionBatchAction] = [.restart, .close, .archive, .unarchive]

  private func request(_ plan: SessionBatchPlan) {
    Task { await model.requestBatch(plan) }
  }
}
