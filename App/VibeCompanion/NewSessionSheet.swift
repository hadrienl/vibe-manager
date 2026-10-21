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
  /// The icon picked; `nil` leaves it to the Mac.
  @State private var appearance: RemoteAppearance?
  @State private var showsIcons = false
  /// Folders picked in the browser, shown first among the recent ones.
  @State private var extraFolders: [String] = []
  /// The browser's way down, emptied when a folder is chosen.
  @State private var browsing: [String] = []

  private var shownFolders: [String] {
    let recent = (options?.folders ?? []).filter { !extraFolders.contains($0) }
    return extraFolders + recent.prefix(8)
  }

  private var options: RemoteNewSessionOptions? { channel.newSessionOptions }
  /// The chosen folder's project icon, worn unless another is picked.
  private var projectIcon: UIImage? { folder.flatMap { channel.folderIcons[$0] ?? nil } }
  private var agent: RemoteAgent? { options?.agents.first { $0.id == agentID } }

  var body: some View {
    NavigationStack(path: $browsing) {
      Form {
        if let options {
          Section("Dossier") {
            if options.folders.isEmpty {
              Text("Aucun dossier récent sur le Mac.").foregroundStyle(.secondary)
            }
            ForEach(shownFolders, id: \.self) { path in
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
          Section {
            NavigationLink("Autres dossiers du Mac…", value: FolderBrowser.home)
          }
          Section("Session") {
            HStack(spacing: 12) {
              Button {
                showsIcons = true
              } label: {
                if appearance == nil, let icon = projectIcon {
                  Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                } else {
                  SessionBadge(
                    appearance: appearance
                      ?? RemoteAppearance(symbol: "sparkles", color: "#8E8E93"),
                    activity: .idle, size: 38)
                }
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Changer l’icône")
              TextField("Nom (tiré du message si vide)", text: $name)
            }
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
          Section {
            TextField("Ce que l’agent doit faire…", text: $prompt, axis: .vertical)
              .lineLimit(4...10)
          } header: {
            HStack {
              Text("Premier message")
              Spacer()
              if !options.templates.isEmpty {
                Menu("Modèles de prompt") {
                  ForEach(options.templates) { template in
                    Button(template.name) { apply(template) }
                  }
                }
                .font(.footnote)
                .textCase(nil)
              }
            }
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
      .navigationDestination(for: String.self) { path in
        FolderBrowser(path: path == FolderBrowser.home ? nil : path) { chosen in
          folder = chosen
          if !extraFolders.contains(chosen) { extraFolders.insert(chosen, at: 0) }
        }
      }
      .onAppear { channel.askNewSessionOptions() }
      .sheet(isPresented: $showsIcons) {
        IconPicker(
          symbols: options?.symbols ?? [], colors: options?.colors ?? [], projectIcon: projectIcon,
          appearance: $appearance
        )
        .presentationDetents([.medium, .large])
      }
      .onReceive(NotificationCenter.default.publisher(for: .folderChosen)) { _ in
        browsing = []
      }
      .onChange(of: options, initial: true) { _, options in
        guard let options else { return }
        if folder == nil { folder = options.folders.first }
        if agentID == nil { agentID = options.agents.first?.id }
      }
      .onChange(of: agentID) { _, _ in modelID = nil }
      .onChange(of: folder, initial: true) { _, folder in
        if let folder { channel.askFolderIcon(folder) }
      }
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
        start: start, coordinates: coordinates, appearance: appearance))
  }

  /// A template fills in the message, and its folder and icon when it has them; its `{{fields}}`
  /// are left in the text to be written over.
  private func apply(_ template: RemoteTemplate) {
    prompt = template.body
    if let folder = template.folder {
      self.folder = folder
      if !extraFolders.contains(folder), options?.folders.contains(folder) != true {
        extraFolders.insert(folder, at: 0)
      }
    }
    if let templateAppearance = template.appearance { appearance = templateAppearance }
  }

  /// `/Users/me/Documents` as `~/Documents`.
  static func abbreviated(_ path: String) -> String {
    guard let range = path.range(of: #"^/Users/[^/]+"#, options: .regularExpression) else {
      return path
    }
    return path.replacingCharacters(in: range, with: "~")
  }
}

/// A folder of the Mac, its subfolders listed by the Mac: the way down to the one a session works
/// in.
struct FolderBrowser: View {
  /// The way to the home folder, which only the Mac knows the path of.
  static let home = "~"
  let path: String?
  let choose: (String) -> Void
  @Environment(RemoteChannel.self) private var channel
  @Environment(\.dismiss) private var dismiss

  private var resolved: String? { path ?? channel.homePath }
  private var listing: RemoteFolderListing? { resolved.flatMap { channel.folderListings[$0] } }

  var body: some View {
    List {
      if let listing {
        if let problem = listing.problem {
          Text(verbatim: problem).foregroundStyle(.secondary)
        } else if listing.folders.isEmpty {
          Text("Aucun sous-dossier.").foregroundStyle(.secondary)
        }
        ForEach(listing.folders, id: \.self) { name in
          NavigationLink(value: (listing.path as NSString).appendingPathComponent(name)) {
            Label(name, systemImage: "folder")
          }
        }
      } else {
        ProgressView().frame(maxWidth: .infinity)
      }
    }
    .navigationTitle(resolved.map { ($0 as NSString).lastPathComponent } ?? "Dossiers")
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom) {
      if let resolved {
        Button {
          choose(resolved)
          dismissToSheet()
        } label: {
          Text("Choisir « \((resolved as NSString).lastPathComponent) »")
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.glassProminent)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
      }
    }
    .onAppear { channel.list(path) }
  }

  /// Back to the sheet, however deep the browser went.
  private func dismissToSheet() {
    NotificationCenter.default.post(name: .folderChosen, object: nil)
  }
}

extension Notification.Name {
  static let folderChosen = Notification.Name("eu.hadrien.VibeManager.Companion.folderChosen")
}

/// The symbols and colours the Mac's Settings offer, as its icon popover lays them out.
struct IconPicker: View {
  let symbols: [String]
  let colors: [String]
  /// The folder's project icon, offered first: what `nil` stands for when there is one.
  var projectIcon: UIImage?
  @Binding var appearance: RemoteAppearance?
  @Environment(\.dismiss) private var dismiss

  private var symbol: String { appearance?.symbol ?? symbols.first ?? "terminal" }
  private var color: String { appearance?.color ?? colors.first ?? "#5E5CE6" }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let projectIcon {
            Button {
              appearance = nil
            } label: {
              HStack(spacing: 12) {
                Image(uiImage: projectIcon)
                  .resizable()
                  .scaledToFit()
                  .frame(width: 44, height: 44)
                Text("Icône du projet")
                Spacer()
                if appearance == nil { Image(systemName: "checkmark").foregroundStyle(.tint) }
              }
            }
            .buttonStyle(.plain)
          }
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 10)], spacing: 10) {
            ForEach(colors, id: \.self) { hex in
              Button {
                appearance = RemoteAppearance(symbol: symbol, color: hex)
              } label: {
                Circle()
                  .fill(Color(hex: hex) ?? .gray)
                  .frame(width: 34, height: 34)
                  .overlay {
                    if hex == color {
                      Image(systemName: "checkmark").font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                    }
                  }
              }
              .accessibilityLabel(hex)
            }
          }
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 10)], spacing: 10) {
            ForEach(symbols, id: \.self) { name in
              Button {
                appearance = RemoteAppearance(symbol: name, color: color)
              } label: {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .fill(name == symbol ? (Color(hex: color) ?? .gray) : Color(.tertiarySystemFill))
                  .frame(width: 44, height: 44)
                  .overlay {
                    Image(systemName: name)
                      .foregroundStyle(name == symbol ? Color.white : .primary)
                  }
              }
              .accessibilityLabel(name)
            }
          }
        }
        .padding(16)
      }
      .navigationTitle("Icône")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("OK", systemImage: "checkmark") { dismiss() }
        }
        ToolbarItem(placement: .cancellationAction) {
          Button("Par défaut") {
            appearance = nil
            dismiss()
          }
        }
      }
    }
  }
}
