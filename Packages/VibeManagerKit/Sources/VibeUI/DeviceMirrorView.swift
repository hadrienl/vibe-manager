import AVFoundation
import AppKit
import CompanionCore
import SwiftUI
import VibeDevices

/// A simulator in a tab of the web view. `sim-bridge`, a process of its own, holds the
/// private frameworks; this view shows its H.264 and sends it the mouse as touches.
struct DeviceMirrorView: NSViewRepresentable {
  let udid: String

  func makeNSView(context: Context) -> DeviceMirrorNSView {
    let view = DeviceMirrorNSView()
    view.start(udid: udid)
    return view
  }

  func updateNSView(_ view: DeviceMirrorNSView, context: Context) {
    view.start(udid: udid)
  }

  static func dismantleNSView(_ view: DeviceMirrorNSView, coordinator: ()) {
    view.stop()
  }
}

final class DeviceMirrorNSView: NSView {
  private let video = AVSampleBufferDisplayLayer()
  private var session: DeviceMirrorSession?
  private var udid: String?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    video.videoGravity = .resizeAspect
    layer?.addSublayer(video)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    video.frame = bounds
    CATransaction.commit()
  }

  func start(udid: String) {
    guard self.udid != udid else { return }
    stop()
    self.udid = udid
    session = DeviceMirrorSession(udid: udid, video: video)
  }

  func stop() {
    session?.stop()
    session = nil
    udid = nil
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) { send("d", event) }
  override func mouseDragged(with event: NSEvent) { send("m", event) }
  override func mouseUp(with event: NSEvent) { send("u", event) }

  private func send(_ phase: String, _ event: NSEvent) {
    guard let session, let size = session.videoSize, size.width > 0 else { return }
    let shown = AVMakeRect(aspectRatio: size, insideRect: bounds)
    let point = convert(event.locationInWindow, from: nil)
    let x = min(max((point.x - shown.minX) / shown.width, 0), 1)
    let y = min(max((point.y - shown.minY) / shown.height, 0), 1)
    session.send("\(phase) \(x) \(y)\n")
  }
}

/// The bridge and the thread that reads it.
private final class DeviceMirrorSession: @unchecked Sendable {
  private let bridge: DeviceBridge?
  private let video: AVSampleBufferDisplayLayer
  private let lock = NSLock()
  private var size: CGSize?

  var videoSize: CGSize? {
    lock.withLock { size }
  }

  init(udid: String, video: AVSampleBufferDisplayLayer) {
    self.video = video
    video.sampleBufferRenderer.flush()
    bridge = Bundle.main.executableURL.flatMap {
      try? DeviceBridge(device: udid, bridgesIn: $0.deletingLastPathComponent())
    }
    guard let bridge else { return }
    Thread.detachNewThread { [self] in read(bridge) }
  }

  func stop() {
    bridge?.stop()
  }

  func send(_ line: String) {
    bridge?.send(line)
  }

  private func read(_ bridge: DeviceBridge) {
    var decoder = CompanionMirror.FrameDecoder()
    while let frame = bridge.nextFrame() {
      guard let sample = decoder.sample(from: frame) else { continue }
      let shown = decoder.size
      lock.withLock { size = shown }
      video.sampleBufferRenderer.enqueue(sample)
    }
  }
}

/// Beside the web view's button, what opens a simulator in one of its tabs.
struct DeviceMirrorToolbarButton: View {
  let model: AppModel
  @State private var isShowingDevices = false

  var body: some View {
    Button {
      isShowingDevices.toggle()
    } label: {
      Label {
        Text("Simulators", bundle: .module)
      } icon: {
        Image(systemName: "iphone")
      }
    }
    .disabled(!model.isWebViewAvailable)
    .popover(isPresented: $isShowingDevices, arrowEdge: .bottom) {
      DeviceMirrorPicker { udid, name in
        isShowingDevices = false
        guard let url = URL(string: "vibe-device://\(udid)") else { return }
        model.openDeviceTab(url, title: name)
      }
    }
  }
}

struct DeviceMirrorPicker: View {
  let open: (_ udid: String, _ name: String) -> Void
  @State private var devices: [(udid: String, name: String)]?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let devices {
        if devices.isEmpty { Text("No simulator or emulator running", bundle: .module).padding(8) }
        ForEach(devices, id: \.udid) { device in
          Button(device.name) { open(device.udid, device.name) }
            .buttonStyle(.borderless)
            .padding(6)
        }
      } else {
        ProgressView().padding(8)
      }
    }
    .padding(6)
    .frame(minWidth: 200, alignment: .leading)
    .task {
      devices = await DeviceCatalog.running().map { ($0.id, $0.name) }
    }
  }

}
