import AVFoundation
import AppKit
import QuickLook
import SwiftUI
import VibeApplication

/// The files that came with a message, under its text (#209): a thumbnail, a player or a chip
/// each, as their type says. A click opens Quick Look, ← and → going through the message's files.
struct AttachmentStrip: View {
  let attachments: [MessageAttachment]
  var alignment: HorizontalAlignment = .leading
  @State private var quickLook: URL?
  @State private var quickLookItems: [URL] = []

  var body: some View {
    AttachmentFlow(spacing: 8, alignment: alignment) {
      ForEach(Array(attachments.enumerated()), id: \.element.id) { rank, attachment in
        AttachmentTile(
          attachment: attachment, name: Self.name(of: attachment, rank: rank)
        ) {
          Task { await preview(attachment) }
        }
      }
    }
    .quickLookPreview($quickLook, in: quickLookItems)
    .onChange(of: quickLook) { _, url in
      if url == nil { Task { await AttachmentPreviews.shared.discardTemporaryFiles() } }
    }
  }

  /// The file's name, or « Image 2 » for an image pasted without one: its rank among the images.
  static func name(of attachment: MessageAttachment, rank: Int) -> String {
    attachment.name ?? String(localized: "Image \(rank + 1)", bundle: .module)
  }

  /// Quick Look on `attachment`, among the files of the message it can show.
  private func preview(_ attachment: MessageAttachment) async {
    var items: [URL] = []
    var selected: URL?
    for other in attachments {
      let rank = attachments.firstIndex(of: other) ?? 0
      guard
        let url = await AttachmentPreviews.shared.previewableFile(
          for: other, name: Self.name(of: other, rank: rank))
      else { continue }
      items.append(url)
      if other.id == attachment.id { selected = url }
    }
    guard let selected else {
      let exists = attachment.file.map { FileManager.default.fileExists(atPath: $0.path) } == true
      announce(
        exists
          ? String(localized: "No preview for this file", bundle: .module)
          : String(localized: "File not found", bundle: .module))
      return
    }
    quickLookItems = items
    quickLook = selected
  }
}

@MainActor
private func announce(_ text: String) {
  NSAccessibility.post(
    element: NSApp as Any, notification: .announcementRequested,
    userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
}

/// One attachment, drawn for its type.
struct AttachmentTile: View {
  static let imageHeight: Double = 120
  /// A chip's: an icon of 28 points and its margins.
  static let chipHeight: Double = 40
  /// A panorama is cropped to it.
  static let maximumWidth: Double = 360

  let attachment: MessageAttachment
  let name: String
  let showPreview: () -> Void
  @State private var preview: AttachmentPreview?

  /// The thumbnails' size in pixels: one for every screen, so that the cache answers at once.
  static let maxPixel = Int(imageHeight * 2 * 2)

  init(attachment: MessageAttachment, name: String, showPreview: @escaping () -> Void) {
    self.attachment = attachment
    self.name = name
    self.showPreview = showPreview
    // What the cache already holds is drawn at once: a row built again while scrolling keeps
    // its height.
    _preview = State(
      initialValue: AttachmentPreviews.shared.cachedPreview(
        for: attachment, maxPixel: Self.maxPixel))
  }
  @Environment(\.displayScale) private var displayScale
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance
  @Environment(\.conversationLinks) private var links

  var body: some View {
    content
      .contextMenu { menu }
      .help(attachment.file?.path ?? name)
      // Again when its source changes: the file of a pasted image is named a line later.
      .task(id: attachment) {
        let preview = await AttachmentPreviews.shared.preview(
          for: attachment, maxPixel: Self.maxPixel)
        if !Task.isCancelled { self.preview = preview }
      }
  }

  /// What the tile shows, as `style(for:preview:)` chooses.
  enum Style: Equatable {
    case loading, image, video, pdf, text, audio, chip, missing
  }

  static func style(for kind: MessageAttachment.Kind, preview: AttachmentPreview?) -> Style {
    guard let preview else { return kind == .audio ? .audio : .loading }
    if preview.isMissing { return .missing }
    switch kind {
    case .image: return preview.thumbnail == nil ? .chip : .image
    case .video: return preview.thumbnail == nil ? .chip : .video
    case .pdf: return preview.thumbnail == nil ? .chip : .pdf
    case .text: return preview.lines == nil ? .chip : .text
    case .audio: return .audio
    case .other: return .chip
    }
  }

  @ViewBuilder
  private var content: some View {
    switch Self.style(for: attachment.kind, preview: preview) {
    case .loading:
      // The size of what comes: a picture, or a chip.
      let isPicture = [.image, .video, .pdf, .text].contains(attachment.kind)
      RoundedRectangle(cornerRadius: isPicture ? 8 : 9)
        .fill(theme.surface.color)
        .frame(
          width: isPicture ? 160 : 200,
          height: isPicture ? Self.imageHeight : Self.chipHeight)
    case .image:
      tileButton { thumbnail }
    case .video:
      tileButton {
        thumbnail.overlay {
          Image(systemName: "play.circle.fill")
            .font(.system(size: 34))
            .foregroundStyle(.white, .black.opacity(0.45))
        }
        .overlay(alignment: .bottomTrailing) {
          if let duration = preview?.duration { badge(Self.formatted(duration)) }
        }
      }
    case .pdf:
      tileButton {
        thumbnail.overlay(alignment: .bottomTrailing) {
          if let pages = preview?.pageCount {
            badge(String(localized: "\(pages) pages", bundle: .module))
          }
        }
      }
    case .text:
      tileButton { textExcerpt }
    case .audio:
      AttachmentAudioPlayer(
        file: attachment.file, name: name, duration: preview?.duration, showPreview: showPreview)
    case .chip:
      tileButton { chip(missing: false) }
    case .missing:
      tileButton { chip(missing: true) }
    }
  }

  /// The tile as one button: a click, or Space once it has the focus, opens Quick Look.
  private func tileButton(@ViewBuilder _ label: () -> some View) -> some View {
    Button(action: showPreview, label: label)
      .buttonStyle(.plain)
      .accessibilityLabel(accessibilityLabel)
  }

  @ViewBuilder
  private var thumbnail: some View {
    if let image = preview?.thumbnail {
      let height = min(Self.imageHeight, Double(image.height) / displayScale)
      let aspect = Double(image.width) / Double(max(image.height, 1))
      Image(decorative: image, scale: 1)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: min(height * aspect, Self.maximumWidth), height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border.color))
    }
  }

  private var textExcerpt: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text(verbatim: name).lineLimit(1).truncationMode(.middle)
      } icon: {
        Image(systemName: "doc.text")
      }
      .font(theme.interfaceFont(size: appearance.textSize.scaled(11), weight: .semibold))
      .foregroundStyle(theme.secondaryText.color)
      Text(verbatim: preview?.lines ?? "")
        .font(theme.codeFont(size: appearance.textSize.scaled(11)))
        .foregroundStyle(theme.text.color)
        .lineLimit(AttachmentPreviews.textLineCount)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(10)
    .frame(width: 260, height: Self.imageHeight, alignment: .topLeading)
    .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border.color))
  }

  private func chip(missing: Bool) -> some View {
    HStack(spacing: 8) {
      Group {
        if !missing, let icon = preview?.icon {
          Image(nsImage: icon).resizable()
        } else {
          Image(systemName: missing ? "questionmark.folder" : "photo")
            .font(.system(size: 18))
            .foregroundStyle(theme.secondaryText.color)
        }
      }
      .frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: name)
          .font(theme.interfaceFont(size: appearance.textSize.scaled(12), weight: .semibold))
          .foregroundStyle(missing ? theme.secondaryText.color : theme.text.color)
          .lineLimit(1)
          .truncationMode(.middle)
        Group {
          if missing {
            Text("File not found", bundle: .module)
          } else if let bytes = preview?.byteCount {
            Text(
              verbatim: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
          }
        }
        .font(theme.interfaceFont(size: appearance.textSize.scaled(11)))
        .foregroundStyle(theme.secondaryText.color)
      }
    }
    .padding(.leading, 6)
    .padding(.trailing, 10)
    .frame(maxWidth: 260, minHeight: Self.chipHeight, alignment: .leading)
    .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.border.color))
    .opacity(missing ? 0.7 : 1)
  }

  private func badge(_ text: String) -> some View {
    Text(verbatim: text)
      .font(.system(size: 10, weight: .semibold).monospacedDigit())
      .foregroundStyle(.white)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
      .padding(5)
  }

  static func formatted(_ seconds: Double) -> String {
    Duration.seconds(seconds.rounded()).formatted(.time(pattern: .minuteSecond))
  }

  // MARK: - Menu

  /// Read from the preview, worked out off the main actor: the menu is built with the tile.
  @ViewBuilder
  private var menu: some View {
    let file = preview?.existingFile
    Button {
      // Checked again: the file may have changed since the tile was drawn.
      // Opens outside: a document a transcript names, which `AttachmentOpening.canOpen` lets out
      // only when it is read by its application — never a program, a script or a link (ADR 0025).
      if let file, AttachmentOpening.canOpen(file) { NSWorkspace.shared.open(file) }
    } label: {
      Text("Open", bundle: .module)
    }
    .disabled(preview?.canOpen != true)
    Button {
      if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    } label: {
      Text("Show in Finder", bundle: .module)
    }
    .disabled(file == nil)
    Button {
      copy(file: file)
    } label: {
      Text("Copy", bundle: .module)
    }
    .disabled(file == nil && attachment.embeddedImage == nil)
    if let links, links.hasWebView(), let file, preview?.canShowInWebView == true {
      Button {
        // Opens outside: the session's own link rule, into its web view, for a page or an image.
        links.open(file, .webView)
      } label: {
        Text("Open in Web View", bundle: .module)
      }
    }
  }

  /// The file itself on the pasteboard, as the Finder copies it; the image when the transcript
  /// alone holds it.
  private func copy(file: URL?) {
    let pasteboard = NSPasteboard.general
    if let file {
      pasteboard.clearContents()
      pasteboard.writeObjects([file as NSURL])
    } else if let image = attachment.embeddedImage,
      let data = AttachmentPreviews.shared.imageData(image), let picture = NSImage(data: data)
    {
      pasteboard.clearContents()
      pasteboard.writeObjects([picture])
    }
  }

  // MARK: - Accessibility

  private var accessibilityLabel: Text {
    let kind: Text =
      switch attachment.kind {
      case .image: Text("Image", bundle: .module)
      case .audio: Text("Audio", bundle: .module)
      case .video: Text("Video", bundle: .module)
      case .pdf: Text(verbatim: "PDF")
      case .text: Text("Text", bundle: .module)
      case .other: Text("File", bundle: .module)
      }
    if preview?.isMissing == true {
      return Text("File not found, \(name)", bundle: .module)
    }
    if let pages = preview?.pageCount {
      return kind
        + Text(verbatim: ", \(name), \(String(localized: "\(pages) pages", bundle: .module))")
    }
    return kind + Text(verbatim: ", \(name)")
  }
}

/// A sound joined to a message: played only when asked (#209).
struct AttachmentAudioPlayer: View {
  let file: URL?
  let name: String
  let duration: Double?
  let showPreview: () -> Void
  @State private var playback = AudioPlayback()
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    HStack(spacing: 10) {
      Button {
        if let file { playback.toggle(file) }
      } label: {
        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 13))
          .frame(width: 28, height: 28)
          .background(theme.accent.color.opacity(0.18), in: Circle())
          .foregroundStyle(theme.accent.color)
      }
      .buttonStyle(.plain)
      .disabled(file == nil)
      .accessibilityLabel(
        playback.isPlaying
          ? Text("Pause \(name)", bundle: .module) : Text("Play \(name)", bundle: .module))
      Button(action: showPreview) {
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: name)
            .accessibilityLabel(Text("Audio", bundle: .module) + Text(verbatim: ", \(name)"))
            .font(theme.interfaceFont(size: appearance.textSize.scaled(12), weight: .semibold))
            .foregroundStyle(theme.text.color)
            .lineLimit(1)
            .truncationMode(.middle)
          ProgressView(value: playback.progress(of: duration))
            .progressViewStyle(.linear)
            .tint(theme.accent.color)
        }
      }
      .buttonStyle(.plain)
      Text(verbatim: duration.map(AttachmentTile.formatted) ?? "–:––")
        .font(theme.interfaceFont(size: appearance.textSize.scaled(11)).monospacedDigit())
        .foregroundStyle(theme.secondaryText.color)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(width: 260)
    .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.border.color))
    .onDisappear { playback.stop() }
  }
}

/// The player of one sound, made at the first ▶︎ and let go when its row leaves the screen.
@MainActor
@Observable
final class AudioPlayback {
  private(set) var isPlaying = false
  private(set) var elapsed: Double = 0
  @ObservationIgnored private var player: AVPlayer?
  @ObservationIgnored private var observer: Any?
  @ObservationIgnored private var end: NSObjectProtocol?

  func toggle(_ file: URL) {
    if isPlaying {
      player?.pause()
      isPlaying = false
      return
    }
    if player == nil { start(file) }
    player?.play()
    isPlaying = true
  }

  func progress(of duration: Double?) -> Double {
    guard let duration, duration > 0 else { return 0 }
    return min(elapsed / duration, 1)
  }

  func stop() {
    player?.pause()
    if let observer { player?.removeTimeObserver(observer) }
    if let end { NotificationCenter.default.removeObserver(end) }
    observer = nil
    end = nil
    player = nil
    isPlaying = false
  }

  private func start(_ file: URL) {
    let player = AVPlayer(url: file)
    observer = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated { self?.elapsed = time.seconds }
    }
    end = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.isPlaying = false
        self?.elapsed = 0
        self?.player?.seek(to: .zero)
      }
    }
    self.player = player
  }
}

/// Lays its views out in lines, going to the next when one is full, each line aligned as asked.
struct AttachmentFlow: Layout {
  var spacing: Double
  var alignment: HorizontalAlignment

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let lines = lines(for: proposal.width ?? .infinity, subviews: subviews)
    let width = lines.map(\.width).max() ?? 0
    let height = lines.map(\.height).reduce(0, +) + spacing * Double(max(lines.count - 1, 0))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for line in lines(for: bounds.width, subviews: subviews) {
      var x =
        alignment == .trailing
        ? bounds.maxX - line.width
        : alignment == .center ? bounds.midX - line.width / 2 : bounds.minX
      for index in line.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(
          at: CGPoint(x: x, y: y + line.height - size.height), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += line.height + spacing
    }
  }

  private struct Line {
    var indices: [Int] = []
    var width: Double = 0
    var height: Double = 0
  }

  private func lines(for maxWidth: Double, subviews: Subviews) -> [Line] {
    var lines: [Line] = []
    var line = Line()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      if !line.indices.isEmpty, line.width + spacing + size.width > maxWidth {
        lines.append(line)
        line = Line()
      }
      line.width += (line.indices.isEmpty ? 0 : spacing) + size.width
      line.height = max(line.height, size.height)
      line.indices.append(index)
    }
    if !line.indices.isEmpty { lines.append(line) }
    return lines
  }
}
