import Darwin
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminal

@Suite("The terminal host's wire")
struct TerminalHostWireTests {
  private let frames: [TerminalHostFrame] = [
    .control(TerminalHostRequest(request: 7, body: .list)),
    .terminal(.input, session: SessionID(), bytes: Array("ls -la\r".utf8)),
    .terminal(.output, session: SessionID(), bytes: [0x1B, 0x5B, 0x32, 0x4A, 0xE2, 0x94]),
    TerminalHostFrame(kind: .output, payload: []),
  ]

  @Test("Frames come back as they were sent")
  func roundTrip() throws {
    var decoder = TerminalHostFrameDecoder()
    let bytes = frames.flatMap(\.encoded)

    #expect(try decoder.append(bytes) == frames)
  }

  @Test("A stream cut anywhere, even inside a header, still yields every frame once")
  func cutAnywhere() throws {
    let bytes = frames.flatMap(\.encoded)
    for cut in 0...bytes.count {
      var decoder = TerminalHostFrameDecoder()
      var decoded = try decoder.append(bytes[0..<cut])
      decoded += try decoder.append(bytes[cut...])
      #expect(decoded == frames, "cut at \(cut)")
    }
  }

  @Test("A length beyond the limit is refused rather than allocated")
  func refusesOversizedPayload() {
    var decoder = TerminalHostFrameDecoder()
    let length = TerminalHostWire.maximumPayloadLength + 1
    let header: [UInt8] = [
      UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff),
      UInt8(length & 0xff), TerminalHostFrameKind.output.rawValue,
    ]

    #expect(throws: TerminalHostFrameError.payloadTooLong(length)) {
      _ = try decoder.append(header)
    }
  }

  @Test("An unknown kind of frame is refused")
  func refusesUnknownKind() {
    var decoder = TerminalHostFrameDecoder()

    #expect(throws: TerminalHostFrameError.unknownKind(9)) {
      _ = try decoder.append([0, 0, 0, 0, 9])
    }
  }

  @Test("Terminal bytes carry the session they belong to")
  func terminalBytesNameTheirSession() {
    let id = SessionID()
    let frame = TerminalHostFrame.terminal(.output, session: id, bytes: [1, 2, 3])

    #expect(frame.terminalBytes?.session == id)
    #expect(frame.terminalBytes?.bytes == [1, 2, 3])
    #expect(TerminalHostFrame(kind: .output, payload: [1, 2]).terminalBytes == nil)
  }

  @Test("Terminal bytes too large for a frame are cut, and come back whole")
  func terminalBytesAreCut() throws {
    let id = SessionID()
    let bytes = (0..<2_500_000).map { UInt8(truncatingIfNeeded: $0) }

    let frames = TerminalHostFrame.terminalChunks(.output, session: id, bytes: bytes)

    #expect(frames.count == 3)
    #expect(frames.allSatisfy { $0.payload.count <= TerminalHostWire.maximumPayloadLength })
    var decoder = TerminalHostFrameDecoder()
    let decoded = try decoder.append(frames.flatMap(\.encoded))
    #expect(decoded.compactMap(\.terminalBytes).flatMap(\.bytes) == bytes)
    #expect(decoded.allSatisfy { $0.terminalBytes?.session == id })
  }

  @Test("A start request carries the whole spec, environment included")
  func startRequestRoundTrip() {
    let spec = TerminalTestSupport.spec(
      script: "echo hi", size: TerminalSize(columns: 132, rows: 40), initialInput: "go\r")
    let request = TerminalHostRequest(request: 3, body: .start(session: SessionID(), spec: spec))

    #expect(TerminalHostFrame.control(request).decode(TerminalHostRequest.self) == request)
  }

  @Test("A failure to start travels as the error it is")
  func startFailureRoundTrip() {
    let message = TerminalHostMessage(
      request: 4, body: .startFailed(.executableNotFound(path: "/nowhere/claude")))

    #expect(TerminalHostFrame.control(message).decode(TerminalHostMessage.self) == message)
  }

  @Test("The kernel says what a running process was signed as, whatever is on disk now")
  func kernelIdentityOfThisProcess() throws {
    var token = audit_token_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &token) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
      }
    }
    try #require(status == KERN_SUCCESS)

    let identity = KernelCodeIdentity.read(token)

    // The test binary is signed ad hoc by the linker: an identifier, and no team.
    #expect(identity?.identifier.isEmpty == false)
    #expect(identity?.team == nil)
  }
}
