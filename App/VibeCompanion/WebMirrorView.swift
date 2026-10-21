import CompanionCore
import SwiftUI

/// A session's web view, as the Mac shows it (#400): the picture of its page, kept in step both
/// ways — a touch here clicks there, a page the agent opens there shows here.
struct WebMirrorView: View {
  let sessionID: String
  @Environment(RemoteChannel.self) private var channel
  @State private var address = ""
  @State private var typing = ""
  @State private var editingAddress = false
  @State private var showsKeyboardField = false
  @FocusState private var addressFocused: Bool

  private var state: RemoteWebState? {
    channel.webState?.sessionID == sessionID ? channel.webState : nil
  }
  private var activeTab: RemoteWebTab? {
    state?.tabs.first { $0.id == state?.activeTabID }
  }

  var body: some View {
    VStack(spacing: 0) {
      addressBar
      page
    }
    .navigationTitle("Vue web")
    .navigationSubtitle("Synchronisée avec le Mac")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu("Onglets", systemImage: "square.on.square") {
          ForEach(state?.tabs ?? []) { tab in
            Button {
              channel.web(.selectTab(tab.id), in: sessionID)
            } label: {
              if tab.id == state?.activeTabID {
                Label(tab.title.isEmpty ? tab.url : tab.title, systemImage: "checkmark")
              } else {
                Text(verbatim: tab.title.isEmpty ? tab.url : tab.title)
              }
            }
          }
        }
        .disabled((state?.tabs.count ?? 0) < 2)
      }
      ToolbarItemGroup(placement: .bottomBar) {
        Button("Page précédente", systemImage: "chevron.backward") {
          channel.web(.back, in: sessionID)
        }
        .disabled(state?.canGoBack != true)
        Button("Page suivante", systemImage: "chevron.forward") {
          channel.web(.forward, in: sessionID)
        }
        .disabled(state?.canGoForward != true)
        Spacer()
        Button("Recharger", systemImage: "arrow.clockwise") { channel.web(.reload, in: sessionID) }
        Button("Clavier", systemImage: "keyboard") { showsKeyboardField = true }
      }
    }
    .alert("Taper dans la page", isPresented: $showsKeyboardField) {
      TextField("Texte", text: $typing)
      Button("Envoyer") {
        channel.web(.type(typing), in: sessionID)
        typing = ""
      }
      Button("Envoyer et valider") {
        channel.web(.type(typing + "\n"), in: sessionID)
        typing = ""
      }
      Button("Annuler", role: .cancel) { typing = "" }
    } message: {
      Text("Le texte va dans le champ touché en dernier.")
    }
    .onAppear { channel.showWeb(sessionID) }
    .onDisappear { channel.showWeb(nil) }
    .onChange(of: activeTab?.url, initial: true) { _, url in
      if !addressFocused { address = url ?? "" }
    }
  }

  private var addressBar: some View {
    HStack(spacing: 8) {
      Image(systemName: activeTab?.isLoading == true ? "hourglass" : "globe")
        .foregroundStyle(.secondary)
      TextField("Adresse", text: $address)
        .focused($addressFocused)
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.go)
        .onSubmit { channel.web(.navigate(address), in: sessionID) }
      if let count = state?.tabs.count, count > 1,
        let index = state?.tabs.firstIndex(where: { $0.id == state?.activeTabID })
      {
        Text("\(index + 1) sur \(count)").font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .glassEffect(.regular.interactive(), in: Capsule())
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  @ViewBuilder private var page: some View {
    if let image = channel.webFrame, state != nil {
      GeometryReader { geometry in
        let size = Self.fitted(image.size, in: geometry.size)
        Image(uiImage: image)
          .resizable()
          .frame(width: size.width, height: size.height)
          .contentShape(Rectangle())
          .gesture(
            SpatialTapGesture().onEnded { value in
              channel.web(
                .tap(x: value.location.x / size.width, y: value.location.y / size.height),
                in: sessionID)
            }
          )
          .simultaneousGesture(
            DragGesture(minimumDistance: 10).onEnded { value in
              // Content follows the finger: a drag upwards scrolls down.
              channel.web(.scroll(dy: -value.translation.height / size.height), in: sessionID)
            }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .accessibilityLabel("Page web du Mac : \(activeTab?.title ?? "")")
      }
    } else if state != nil, state?.tabs.isEmpty == true {
      ContentUnavailableView {
        Label("Aucune page", systemImage: "globe")
      } description: {
        Text("Tape une adresse pour ouvrir une page dans la vue web du Mac.")
      }
    } else {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// The page's picture at the width it is given, its height in proportion.
  static func fitted(_ image: CGSize, in space: CGSize) -> CGSize {
    guard image.width > 0 else { return space }
    let scale = min(space.width / image.width, space.height / image.height)
    return CGSize(width: image.width * scale, height: image.height * scale)
  }
}
