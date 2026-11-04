import AVFoundation
import AppKit
import SwiftUI
import VibeBrowser

/// POC #480: a simulator in a tab of the web view. `sim-bridge`, a process of its own, holds the
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

/// The bridge's process and the thread that reads it.
private final class DeviceMirrorSession: @unchecked Sendable {
  private let process = Process()
  private let input = Pipe()
  private let video: AVSampleBufferDisplayLayer
  private let lock = NSLock()
  private var size: CGSize?

  var videoSize: CGSize? {
    lock.withLock { size }
  }

  init(udid: String, video: AVSampleBufferDisplayLayer) {
    self.video = video
    video.sampleBufferRenderer.flush()
    let isAndroid = udid.hasPrefix("android-")
    guard let bridge = Bundle.main.url(forAuxiliaryExecutable: isAndroid ? "emu-bridge" : "sim-bridge")
    else { return }
    let output = Pipe()
    process.executableURL = bridge
    process.arguments = [isAndroid ? String(udid.dropFirst("android-".count)) : udid]
    if isAndroid,
      let token = DeviceMirrorPicker.runningEmulators().first(where: { $0.id == udid })?.token
    {
      process.environment = ["EMU_TOKEN": token]
    }
    process.standardInput = input
    process.standardOutput = output
    do { try process.run() } catch { return }
    let reading = output.fileHandleForReading
    Thread.detachNewThread { [self] in read(reading) }
  }

  func stop() {
    try? input.fileHandleForWriting.close()
    if process.isRunning { process.terminate() }
  }

  func send(_ line: String) {
    try? input.fileHandleForWriting.write(contentsOf: Data(line.utf8))
  }

  private func read(_ handle: FileHandle) {
    var format: CMVideoFormatDescription?
    while let header = Self.exactly(4, from: handle) {
      let length = header.reduce(0) { $0 << 8 | Int($1) }
      guard let payload = Self.exactly(length, from: handle), let isKey = payload.first else {
        return
      }
      var offset = 1
      if isKey != 0 {
        guard let sets = Self.parameterSets(in: payload, offset: &offset),
          let made = Self.format(sps: sets.0, pps: sets.1)
        else { return }
        format = made
        let dimensions = CMVideoFormatDescriptionGetDimensions(made)
        lock.withLock { size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height)) }
      }
      guard let format,
        let sample = Self.sample(payload.subdata(in: offset..<payload.count), format: format)
      else { continue }
      video.sampleBufferRenderer.enqueue(sample)
    }
  }

  private static func exactly(_ count: Int, from handle: FileHandle) -> Data? {
    var data = Data(capacity: count)
    while data.count < count {
      guard let part = try? handle.read(upToCount: count - data.count), !part.isEmpty else {
        return nil
      }
      data.append(part)
    }
    return data
  }

  private static func parameterSets(in payload: Data, offset: inout Int) -> (Data, Data)? {
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

  private static func format(sps: Data, pps: Data) -> CMVideoFormatDescription? {
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

  private static func sample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
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

/// The simulators running now, to open one in a tab.
struct DeviceMirrorPicker: View {
  let open: (_ udid: String, _ name: String) -> Void
  @State private var devices: [(udid: String, name: String)]?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let devices {
        if devices.isEmpty { Text(verbatim: "Aucun simulateur ni émulateur démarré").padding(8) }
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
      devices = await Task.detached {
        Self.booted() + Self.runningEmulators().map { ($0.id, $0.name) }
      }.value
    }
  }

  /// POC #480: the Android emulators running now, as the emulator itself lists them. Their id is
  /// `android-<gRPC port>`.
  nonisolated static func runningEmulators() -> [(id: String, name: String, token: String?)] {
    let folder = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return files.compactMap { file in
      let stem = file.deletingPathExtension().lastPathComponent
      guard stem.hasPrefix("pid_"), let pid = Int32(stem.dropFirst(4)), kill(pid, 0) == 0,
        let text = try? String(contentsOf: file, encoding: .utf8)
      else { return nil }
      var values: [String: String] = [:]
      for line in text.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: "=", maxSplits: 1)
        if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
      }
      guard let port = values["grpc.port"] else { return nil }
      return ("android-\(port)", values["avd.name"] ?? "Android", values["grpc.token"])
    }
  }

  private nonisolated static func booted() -> [(udid: String, name: String)] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "list", "devices", "booted", "-j"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let runtimes = root["devices"] as? [String: [[String: Any]]]
    else { return [] }
    return runtimes.values.flatMap { $0 }.compactMap { device in
      guard let udid = device["udid"] as? String, let name = device["name"] as? String else {
        return nil
      }
      return (udid, name)
    }
  }
}
