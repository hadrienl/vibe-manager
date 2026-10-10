import CompanionCore
import Darwin
import Foundation
import Security
import Testing

@testable import CompanionWire

private let ping = CompanionPing(
  nonce: "7F3A", deviceName: "iPhone", sentAt: Date(timeIntervalSince1970: 1_800_000_000))

private let messages: [CompanionLinkMessage] = [
  .hello(protocolVersion: 1, installationID: "A1", version: "1.0.2", buildLabel: "#347 abc"),
  .snapshot([CompanionSessionInfo(id: "1", title: "Notes", agent: "Codex", state: .working)]),
  .testAcknowledged(nonce: "7F3A", receivedAt: Date(timeIntervalSince1970: 1_800_000_002)),
  .welcome(protocolVersion: 1),
  .testReceived(ping),
]

@Test("Messages cut anywhere in the stream come out whole and in order")
func framesSurviveAnyCut() throws {
  let bytes = messages.flatMap(CompanionLinkFrame.encode)
  for chunk in [1, 3, 7, 64, bytes.count] {
    var decoder = CompanionLinkDecoder()
    var decoded: [CompanionLinkMessage] = []
    for start in stride(from: 0, to: bytes.count, by: chunk) {
      decoded += try decoder.append(bytes[start..<min(start + chunk, bytes.count)])
    }
    #expect(decoded == messages, "cut every \(chunk) bytes")
  }
}

@Test("A frame longer than the limit or of an unknown kind ends the stream")
func corruptFrames() {
  #expect(throws: CompanionLinkFrameError.payloadTooLong(0x7FFF_FFFF)) {
    var decoder = CompanionLinkDecoder()
    _ = try decoder.append([0x7F, 0xFF, 0xFF, 0xFF, 1])
  }
  #expect(throws: CompanionLinkFrameError.unknownKind(9)) {
    var decoder = CompanionLinkDecoder()
    _ = try decoder.append([0, 0, 0, 0, 9])
  }
}

@Test("A frame that does not decode is skipped, and the next one still reads")
func undecodableFrameIsSkipped() throws {
  var bytes: [UInt8] = [0, 0, 0, 2, 1, 0x7B, 0x7D]  // `{}`: no message
  bytes += CompanionLinkFrame.encode(.welcome(protocolVersion: 1))
  var decoder = CompanionLinkDecoder()
  #expect(try decoder.append(bytes) == [.welcome(protocolVersion: 1)])
}

private func socketPair() throws -> (Int32, Int32) {
  var descriptors: [Int32] = [0, 0]
  guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
    throw POSIXError(.EIO)
  }
  return (descriptors[0], descriptors[1])
}

@Test("Two connections exchange messages, and closing one ends the other's stream")
func connectionsExchangeMessages() async throws {
  let (left, right) = try socketPair()
  let application = CompanionLinkConnection(descriptor: left)
  let agent = CompanionLinkConnection(descriptor: right)

  application.send(messages[0])
  application.send(messages[1])
  var received: [CompanionLinkMessage] = []
  for await message in agent.messages {
    received.append(message)
    if received.count == 2 { break }
  }
  #expect(received == Array(messages[0...1]))

  agent.send(.testReceived(ping))
  var iterator = application.messages.makeAsyncIterator()
  #expect(await iterator.next() == .testReceived(ping))

  agent.close()
  #expect(await iterator.next() == nil)
}

@Test("Accepting with no connection waiting returns at once instead of holding the caller")
func acceptWithoutConnectionReturns() throws {
  let path = NSTemporaryDirectory() + "companion-\(getpid()).sock"
  defer { unlink(path) }
  let listener = try CompanionSocket.listen(at: path)
  defer { close(listener) }

  #expect(accept(listener, nil, nil) == -1)
  #expect(errno == EAGAIN)
}

@Test("The requirement names the team and the identifier, or the identifier alone ad hoc")
func requirementText() {
  #expect(
    CodeSigningCompanionPeerVerifier.requirementText(
      peerIdentifier: "eu.hadrien.VibeManager.CompanionAgent", team: "QMJKZ67Z3H")
      == "anchor apple generic and identifier \"eu.hadrien.VibeManager.CompanionAgent\" and certificate leaf[subject.OU] = \"QMJKZ67Z3H\""
  )
  #expect(
    CodeSigningCompanionPeerVerifier.requirementText(
      peerIdentifier: "eu.hadrien.VibeManager", team: nil)
      == "identifier \"eu.hadrien.VibeManager\"")
  // Nothing that could close the quotes and widen the requirement.
  #expect(
    CodeSigningCompanionPeerVerifier.requirementText(
      peerIdentifier: "x\" or identifier \"y", team: nil) == nil)
  #expect(
    CodeSigningCompanionPeerVerifier.requirementText(peerIdentifier: "x", team: "Q\" or") == nil)
}

/// The identifier this test process is signed as: ad hoc, by the linker.
private func ownIdentifier() -> String? {
  var code: SecCode?
  var staticCode: SecStaticCode?
  var information: CFDictionary?
  guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
    SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
    SecCodeCopySigningInformation(
      staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
  else { return nil }
  return (information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
}

@Test("A peer signed as another program is refused; one signed as expected is let in")
func peerVerification() throws {
  let (left, right) = try socketPair()
  defer {
    close(left)
    close(right)
  }
  // Both ends are this test process: it is not the companion agent.
  #expect(
    !CodeSigningCompanionPeerVerifier(peerIdentifier: "eu.hadrien.VibeManager.CompanionAgent")
      .accepts(peerOf: left))
  #expect(SameUserCompanionPeerVerifier().accepts(peerOf: left))

  // Signed ad hoc, the test process has no team: what it demands is the identifier alone.
  let identifier = try #require(ownIdentifier())
  #expect(CodeSigningCompanionPeerVerifier(peerIdentifier: identifier).accepts(peerOf: right))
}
