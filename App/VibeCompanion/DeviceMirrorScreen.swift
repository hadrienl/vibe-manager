import AVFoundation
import CompanionCore
import IrohLib
import SwiftUI
import UIKit

/// POC #480: the simulators running on the Mac.
struct DeviceListScreen: View {
  @Environment(RemoteChannel.self) private var channel
  @State private var devices: [CompanionMirror.Device]?
  @State private var failure: String?

  var body: some View {
    List {
      if let devices, devices.isEmpty {
        Text(verbatim: "Aucun simulateur démarré sur le Mac")
      }
      ForEach(devices ?? []) { device in
        NavigationLink(device.name) { DeviceMirrorScreen(device: device) }
      }
      if let failure { Text(verbatim: failure).foregroundStyle(.secondary) }
    }
    .overlay { if devices == nil && failure == nil { ProgressView() } }
    .navigationTitle(Text(verbatim: "Simulateurs"))
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
          Button { attempt += 1 } label: { Text(verbatim: "Reconnecter") }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxHeight: .infinity)
      } else if !isFullScreen {
        // What the measures of the POC read.
        Text(verbatim: session.status)
          .font(.caption2.monospaced())
          .foregroundStyle(.white.opacity(0.7))
          .padding(4)
          .background(.black.opacity(0.5))
          .allowsHitTesting(false)
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
      navigation = sequence(first: self as UIResponder, next: \.next)
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
  var status = "Connexion…"
  private(set) var videoSize: CGSize?
  @ObservationIgnored var video: AVSampleBufferDisplayLayer?
  @ObservationIgnored private var touches: AsyncStream<String>.Continuation?

  func touch(_ line: String) {
    touches?.yield(line)
  }

  /// Until the task is cancelled or the stream fails.
  func run(udid: String, channel: RemoteChannel) async {
    failure = nil
    status = "Connexion…"
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
      let counter = FrameCounter()
      let meter = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1))
          let (frames, bytes) = counter.take()
          self?.status =
            "\(frames) i/s · \(bytes * 8 / 1000) kbit/s · \(CompanionIroh.describe(connection.paths()))"
        }
      }
      defer { meter.cancel() }
      let receiving = stream.recv()
      let size: @Sendable (CGSize) async -> Void = { [weak self] size in
        await MainActor.run { self?.videoSize = size }
      }
      try await Task.detached {
        try await Self.receive(receiving, into: layer, counter: counter, size: size)
      }.value
      if !Task.isCancelled { failure = "Le simulateur ne répond plus." }
    } catch {
      if !Task.isCancelled { failure = CompanionIroh.describe(error) }
    }
    touches = nil
  }

  private nonisolated static func receive(
    _ receiving: RecvStream, into layer: AVSampleBufferDisplayLayer?, counter: FrameCounter,
    size: @Sendable (CGSize) async -> Void
  ) async throws {
    nonisolated(unsafe) let layer = layer
    var format: CMVideoFormatDescription?
    while !Task.isCancelled {
      let length = try await receiving.readExact(size: 4).reduce(0) { $0 << 8 | UInt32($1) }
      let payload = try await receiving.readExact(size: length)
      counter.add(payload.count)
      guard let isKey = payload.first else { continue }
      var offset = 1
      if isKey != 0 {
        guard let sets = parameterSets(in: payload, offset: &offset),
          let made = makeFormat(sps: sets.0, pps: sets.1)
        else { return }
        format = made
        let dimensions = CMVideoFormatDescriptionGetDimensions(made)
        await size(CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))
      }
      guard let format,
        let sample = makeSample(payload.subdata(in: offset..<payload.count), format: format)
      else { continue }
      nonisolated(unsafe) let unsafeSample = sample
      await MainActor.run {
        if layer?.sampleBufferRenderer.status == .failed { layer?.sampleBufferRenderer.flush() }
        layer?.sampleBufferRenderer.enqueue(unsafeSample)
      }
    }
  }

  private nonisolated static func parameterSets(in payload: Data, offset: inout Int) -> (Data, Data)? {
    func next(_ offset: inout Int) -> Data? {
      guard payload.count >= offset + 2 else { return nil }
      let length = Int(payload[offset]) << 8 | Int(payload[offset + 1])
      offset += 2
      guard payload.count >= offset + length else { return nil }
      defer { offset += length }
      return payload.subdata(in: offset..<offset + length)
    }
    guard let sps = next(&offset), let pps = next(&offset) else { return nil }
    return (sps, pps)
  }

  private nonisolated static func makeFormat(sps: Data, pps: Data) -> CMVideoFormatDescription? {
    var format: CMVideoFormatDescription?
    let status = sps.withUnsafeBytes { spsBytes in
      pps.withUnsafeBytes { ppsBytes in
        let pointers = [
          spsBytes.bindMemory(to: UInt8.self).baseAddress!,
          ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
        ]
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
          parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4,
          formatDescriptionOut: &format)
      }
    }
    return status == noErr ? format : nil
  }

  private nonisolated static func makeSample(
    _ data: Data, format: CMVideoFormatDescription
  ) -> CMSampleBuffer? {
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
        customBlockSource: nil, offsetToData: 0, dataLength: data.count,
        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
      let block,
      data.withUnsafeBytes({
        CMBlockBufferReplaceDataBytes(
          with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
          dataLength: data.count)
      }) == noErr
    else { return nil }
    var sample: CMSampleBuffer?
    var size = data.count
    guard
      CMSampleBufferCreateReady(
        allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
      let sample
    else { return nil }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0
    {
      let first = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
  }
}

private final class FrameCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var frames = 0
  private var bytes = 0

  func add(_ count: Int) {
    lock.withLock {
      frames += 1
      bytes += count
    }
  }

  func take() -> (Int, Int) {
    lock.withLock {
      defer {
        frames = 0
        bytes = 0
      }
      return (frames, bytes)
    }
  }
}
