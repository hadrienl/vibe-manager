import AVFoundation
import CompanionCore
import IrohLib
import SwiftUI
import UIKit

/// The simulators running on the Mac.
struct DeviceListScreen: View {
  @Environment(RemoteChannel.self) private var channel
  @State private var devices: [CompanionMirror.Device]?
  @State private var failure: String?

  var body: some View {
    List {
      if let devices, devices.isEmpty {
        Text("No simulator running on the Mac")
      }
      ForEach(devices ?? []) { device in
        NavigationLink(device.name) { DeviceMirrorScreen(device: device) }
      }
      if let failure { Text(verbatim: failure).foregroundStyle(.secondary) }
    }
    .overlay { if devices == nil && failure == nil { ProgressView() } }
    .navigationTitle("Simulators")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task { await load() }
  }

  private func load() async {
    do {
      let connection = try await channel.mirrorConnection()
      defer { try? connection.close(errorCode: 0, reason: Data()) }
      let stream = try await connection.openBi()
      try await stream.send().writeAll(buf: CompanionMirror.message("list"))
      let receiving = stream.recv()
      let length = try await receiving.readExact(size: 4).reduce(0) { $0 << 8 | UInt32($1) }
      let body = try await receiving.readExact(size: length)
      devices = try JSONDecoder().decode([CompanionMirror.Device].self, from: body)
      failure = nil
    } catch {
      failure = CompanionIroh.describe(error)
    }
  }
}

/// One simulator, full width: its video, and the finger as its touches.
struct DeviceMirrorScreen: View {
  let device: CompanionMirror.Device
  @Environment(RemoteChannel.self) private var channel
  @State private var session = DeviceMirrorClient()
  @State private var attempt = 0
  @State private var isFullScreen = false

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black.ignoresSafeArea()
      MirrorVideo(session: session)
        .ignoresSafeArea(edges: isFullScreen ? .all : [])
      if let failure = session.failure {
        VStack(spacing: 12) {
          Text(verbatim: failure).foregroundStyle(.white).multilineTextAlignment(.center)
          Button {
            attempt += 1
          } label: {
            Text("Reconnect")
          }
          .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxHeight: .infinity)
      }
    }
    .overlay(alignment: .topTrailing) {
      // The only way out: the whole screen belongs to the simulator's touches.
      if isFullScreen {
        Button {
          isFullScreen = false
        } label: {
          Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(.black.opacity(0.45), in: Circle())
        }
        .accessibilityLabel(Text("Exit Full Screen"))
        .padding(8)
      }
    }
    .toolbar(isFullScreen ? .hidden : .automatic, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          isFullScreen = true
        } label: {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .accessibilityLabel(Text("Full Screen"))
      }
    }
    .statusBarHidden(isFullScreen)
    .persistentSystemOverlays(isFullScreen ? .hidden : .automatic)
    // The system's own edge swipes ask a second swipe, the first going to the simulator.
    .defersSystemGestures(on: .all)
    .navigationTitle(device.name)
    .navigationBarTitleDisplayMode(.inline)
    .task(id: attempt) {
      await session.run(udid: device.id, channel: channel)
    }
  }
}

private struct MirrorVideo: UIViewRepresentable {
  let session: DeviceMirrorClient

  func makeUIView(context: Context) -> MirrorVideoView {
    let view = MirrorVideoView()
    view.session = session
    session.video = view.video
    return view
  }

  func updateUIView(_ view: MirrorVideoView, context: Context) {}
}

final class MirrorVideoView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  var video: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
  fileprivate var session: DeviceMirrorClient?
  private weak var navigation: UINavigationController?

  override init(frame: CGRect) {
    super.init(frame: frame)
    video.videoGravity = .resizeAspect
    backgroundColor = .black
    isMultipleTouchEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  /// While a simulator is open every finger is the simulator's: only the back button leaves, not
  /// the swipes that pop a screen, from its edge or (iOS 26) anywhere on it.
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      navigation =
        sequence(first: self as UIResponder, next: \.next)
        .compactMap { $0 as? UINavigationController }.first
    }
    navigation?.interactivePopGestureRecognizer?.isEnabled = window == nil
    navigation?.interactiveContentPopGestureRecognizer?.isEnabled = window == nil
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { send("d", touches) }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { send("m", touches) }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { send("u", touches) }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    send("u", touches)
  }

  private func send(_ phase: String, _ touches: Set<UITouch>) {
    guard let session, let size = session.videoSize, size.width > 0, let touch = touches.first
    else { return }
    let shown = AVMakeRect(aspectRatio: size, insideRect: bounds)
    let point = touch.location(in: self)
    let x = min(max((point.x - shown.minX) / shown.width, 0), 1)
    let y = min(max((point.y - shown.minY) / shown.height, 0), 1)
    session.touch("\(phase) \(x) \(y)")
  }
}

/// The stream of one mirror: frames in, touches out, each in its own task.
@MainActor @Observable
final class DeviceMirrorClient {
  var failure: String?
  private(set) var videoSize: CGSize?
  @ObservationIgnored var video: AVSampleBufferDisplayLayer?
  @ObservationIgnored private var touches: AsyncStream<String>.Continuation?

  func touch(_ line: String) {
    touches?.yield(line)
  }

  /// Until the task is cancelled or the stream fails.
  func run(udid: String, channel: RemoteChannel) async {
    failure = nil
    video?.sampleBufferRenderer.flush()
    do {
      let connection = try await channel.mirrorConnection()
      defer { try? connection.close(errorCode: 0, reason: Data()) }
      let stream = try await connection.openBi()
      let sending = stream.send()
      try await sending.writeAll(buf: CompanionMirror.message("open \(udid)"))
      let (lines, continuation) = AsyncStream.makeStream(of: String.self)
      touches = continuation
      let writer = Task.detached {
        for await line in lines {
          try? await sending.writeAll(buf: CompanionMirror.message(line))
        }
      }
      defer {
        writer.cancel()
        continuation.finish()
      }
      nonisolated(unsafe) let layer = video
      let receiving = stream.recv()
      let size: @Sendable (CGSize) async -> Void = { [weak self] size in
        await MainActor.run { self?.videoSize = size }
      }
      let receiver = Task.detached {
        try await Self.receive(receiving, into: layer, size: size)
      }
      // Closing is what ends a read under way; a detached task does not hear the screen leave.
      try await withTaskCancellationHandler {
        try await receiver.value
      } onCancel: {
        receiver.cancel()
        try? connection.close(errorCode: 0, reason: Data())
      }
      if !Task.isCancelled { failure = String(localized: "The simulator stopped responding.") }
    } catch {
      if !Task.isCancelled { failure = CompanionIroh.describe(error) }
    }
    touches = nil
  }

  private nonisolated static func receive(
    _ receiving: RecvStream, into layer: AVSampleBufferDisplayLayer?,
    size: @Sendable (CGSize) async -> Void
  ) async throws {
    nonisolated(unsafe) let layer = layer
    var decoder = CompanionMirror.FrameDecoder()
    while !Task.isCancelled {
      let length = try await receiving.readExact(size: 4).reduce(0) { $0 << 8 | UInt32($1) }
      let payload = try await receiving.readExact(size: length)
      let known = decoder.size
      guard let sample = decoder.sample(from: payload) else { continue }
      if let shown = decoder.size, shown != known { await size(shown) }
      nonisolated(unsafe) let unsafeSample = sample
      await MainActor.run {
        if layer?.sampleBufferRenderer.status == .failed { layer?.sampleBufferRenderer.flush() }
        layer?.sampleBufferRenderer.enqueue(unsafeSample)
      }
    }
  }
}
