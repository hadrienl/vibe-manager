import CompanionCore
import SwiftUI

/// A new session, as the Mac's New Session sheet makes it (#400): a recent folder, the agent and
/// its model, started now or left in À faire, and its first message.
struct NewSessionSheet: View {
  @Environment(RemoteChannel.self) private var channel
  @Environment(\.dismiss) private var dismiss
  @State private var folder: String?
  @State private var name = ""
  @State private var agentID: String?
  @State private var modelID: String?
  @State private var start = true
  @State private var coordinates = false
  @State private var prompt = ""
  @State private var isCreating = false

  private var options: RemoteNewSessionOptions? { channel.newSessionOptions }
  private var agent: RemoteAgent? { options?.agents.first { $0.id == agentID } }

  var body: some View {
    NavigationStack {
      Form {
        if let options {
          Section("Dossier") {
            if options.folders.isEmpty {
              Text("Aucun dossier récent sur le Mac.").foregroundStyle(.secondary)
            }
            ForEach(options.folders.prefix(8), id: \.self) { path in
              Button {
                folder = path
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: folder == path ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(.tint)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: (path as NSString).lastPathComponent).foregroundStyle(.primary)
                    Text(verbatim: Self.abbreviated((path as NSString).deletingLastPathComponent))
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
          Section("Session") {
            TextField("Nom (tiré du message si vide)", text: $name)
            Picker("Agent", selection: $agentID) {
              ForEach(options.agents) { agent in
                Text(verbatim: agent.name).tag(Optional(agent.id))
              }
            }
            .pickerStyle(.menu)
            if let agent, !agent.models.isEmpty {
              Picker("Modèle", selection: $modelID) {
                Text("Par défaut de l’agent").tag(String?.none)
                ForEach(agent.models) { model in
                  Text(verbatim: model.name).tag(Optional(model.id))
                }
              }
              .pickerStyle(.menu)
            }
            Picker("Statut", selection: $start) {
              Text("En cours").tag(true)
              Text("À faire").tag(false)
            }
            .pickerStyle(.menu)
            Toggle("Coordonner d’autres sessions", isOn: $coordinates)
          }
          Section("Premier message") {
            TextField("Ce que l’agent doit faire…", text: $prompt, axis: .vertical)
              .lineLimit(4...10)
          }
        } else {
          ProgressView().frame(maxWidth: .infinity)
        }
      }
      .navigationTitle("Nouvelle session")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Annuler", systemImage: "xmark") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Créer", systemImage: "checkmark") { create() }
            .disabled(folder == nil || agentID == nil || isCreating)
        }
      }
      .onAppear { channel.askNewSessionOptions() }
      .onChange(of: options, initial: true) { _, options in
        guard let options else { return }
        if folder == nil { folder = options.folders.first }
        if agentID == nil { agentID = options.agents.first?.id }
      }
      .onChange(of: agentID) { _, _ in modelID = nil }
      .onChange(of: channel.failure) { _, failure in
        if failure != nil { isCreating = false }
      }
    }
  }

  private func create() {
    guard let folder, let agentID else { return }
    isCreating = true
    channel.create(
      RemoteNewSession(
        name: name, folder: folder, agentID: agentID, modelID: modelID, prompt: prompt,
        start: start, coordinates: coordinates))
  }

  /// `/Users/me/Documents` as `~/Documents`.
  static func abbreviated(_ path: String) -> String {
    guard let range = path.range(of: #"^/Users/[^/]+"#, options: .regularExpression) else {
      return path
    }
    return path.replacingCharacters(in: range, with: "~")
  }
}
