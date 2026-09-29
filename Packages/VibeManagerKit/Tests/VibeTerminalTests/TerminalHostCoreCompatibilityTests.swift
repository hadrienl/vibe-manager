import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminal

/// The frozen core of the host's protocol, as protocol 1 put it on the wire (ADR 0017). An update
/// takes back the agents left running by a host of the version before it (#92): whatever that
/// host says must still be read, and whatever this build asks must still read the same. A change
/// that breaks this test breaks an update with agents running.
@Suite("The frozen core of the host's protocol")
struct TerminalHostCoreCompatibilityTests {
  private static let session = #"{"rawValue":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}"#
  private static let id = TerminalID(
    rawValue: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!)
  private static let instant = Date(timeIntervalSince1970: 1_800_000_000)

  /// What a host of protocol 1 says, as it said it.
  private static let messages: [(String, TerminalHostMessage.Body)] = [
    (
      #"{"welcome":{"capabilities":[],"processIdentifier":4242,"protocolVersion":1,"build":"812","startedAt":821692800}}"#,
      .welcome(
        protocolVersion: 1, build: "812", capabilities: [], processIdentifier: 4242,
        startedAt: instant)
    ),
    (
      #"{"refused":{"reason":"x","refusal":"otherClient"}}"#,
      .refused(reason: "x", refusal: .otherClient)
    ),
    (
      #"{"sessions":{"_0":[{"session":\#(session),"state":{"running":{"processIdentifier":99}}}]}}"#,
      .sessions([
        HostedSessionRecord(
          session: id, state: .running(processIdentifier: 99), endedAt: nil, role: nil)
      ])
    ),
    (#"{"started":{"processIdentifier":99}}"#, .started(processIdentifier: 99)),
    (
      #"{"attached":{"state":{"running":{"processIdentifier":99}},"session":\#(session),"droppedByteCount":0}}"#,
      .attached(session: id, state: .running(processIdentifier: 99), droppedByteCount: 0)
    ),
    (#"{"stopped":{"state":{"exited":{"code":0}}}}"#, .stopped(state: .exited(code: 0))),
    (#"{"done":{}}"#, .done),
    (#"{"unknownSession":{}}"#, .unknownSession),
    (
      #"{"state":{"state":{"exited":{"code":1}},"session":\#(session),"endedAt":821692800}}"#,
      .state(session: id, state: .exited(code: 1), endedAt: instant)
    ),
    (
      #"{"truncated":{"session":\#(session),"droppedByteCount":10}}"#,
      .truncated(session: id, droppedByteCount: 10)
    ),
  ]

  /// What an application of protocol 1 asked, as it asked it.
  private static let requests: [(String, TerminalHostRequest.Body)] = [
    (
      #"{"hello":{"protocolVersion":1,"capabilities":[],"build":"812"}}"#,
      .hello(protocolVersion: 1, build: "812", capabilities: [])
    ),
    (#"{"list":{}}"#, .list),
    (
      #"{"start":{"session":\#(session),"spec":{"workingDirectoryURL":"file:\/\/\/tmp\/","initialSize":{"rows":24,"columns":80},"scrollback":{"maximumLineCount":5000,"maximumByteCount":4194304},"environment":{"PATH":"\/usr\/bin:\/bin","TERM":"xterm-256color"},"executableURL":"file:\/\/\/bin\/sh","arguments":["-c","echo hi"]}}}"#,
      .start(
        session: id,
        spec: TerminalSpec(
          executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo hi"],
          environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
          workingDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
          initialSize: TerminalSize(columns: 80, rows: 24), initialInput: nil,
          scrollback: .default))
    ),
    (#"{"attach":{"session":\#(session)}}"#, .attach(session: id)),
    (
      #"{"resize":{"session":\#(session),"size":{"rows":40,"columns":120}}}"#,
      .resize(session: id, size: TerminalSize(columns: 120, rows: 40))
    ),
    (#"{"redraw":{"session":\#(session)}}"#, .redraw(session: id)),
    (
      #"{"stop":{"session":\#(session),"gracePeriodMilliseconds":3000}}"#,
      .stop(session: id, gracePeriodMilliseconds: 3_000)
    ),
    (#"{"kill":{"session":\#(session)}}"#, .kill(session: id)),
    (#"{"release":{"session":\#(session)}}"#, .release(session: id)),
    (#"{"goodbye":{"keepRunning":true}}"#, .goodbye(keepRunning: true)),
  ]

  private static func frame(_ body: String) -> TerminalHostFrame {
    TerminalHostFrame(kind: .control, payload: Array(#"{"request":5,"body":\#(body)}"#.utf8))
  }

  @Test("What a host of protocol 1 says is read as it meant it")
  func readsAnOlderHost() {
    for (json, body) in Self.messages {
      #expect(
        Self.frame(json).decode(TerminalHostMessage.self)
          == TerminalHostMessage(request: 5, body: body), "\(json)")
    }
  }

  @Test("What this build asks, an older host reads: nothing it knew is renamed or taken away")
  func speaksToAnOlderHost() throws {
    for (json, body) in Self.requests {
      let sent = TerminalHostFrame.control(TerminalHostRequest(request: 5, body: body))
      let now = try JSONSerialization.jsonObject(with: Data(sent.payload))
      let then = try JSONSerialization.jsonObject(with: Data(Self.frame(json).payload))
      // A key added since is ignored by the older host's decoder; one missing would fail it.
      #expect(Self.holds(now, everythingOf: then), "\(json)")
    }
  }

  @Test("What an application of protocol 1 asks is still understood")
  func understandsAnOlderApplication() {
    for (json, body) in Self.requests {
      #expect(
        Self.frame(json).decode(TerminalHostRequest.self)
          == TerminalHostRequest(request: 5, body: body), "\(json)")
    }
  }

  @Test("The core is still protocol 1, and its socket still named after it")
  func protocolOne() {
    #expect(TerminalHost.protocolVersion == 1)
    #expect(
      TerminalHostLocation(directory: URL(fileURLWithPath: "/tmp/h")).socketPath
        == "/tmp/h/host-v1.sock")
  }

  /// Whether `value` has every key of `reference`, with the same values, recursively.
  private static func holds(_ value: Any, everythingOf reference: Any) -> Bool {
    switch (value, reference) {
    case (let value as [String: Any], let reference as [String: Any]):
      return reference.allSatisfy { key, expected in
        value[key].map { holds($0, everythingOf: expected) } ?? false
      }
    case (let value as [Any], let reference as [Any]):
      return value.count == reference.count
        && zip(value, reference).allSatisfy { holds($0, everythingOf: $1) }
    case (let value as NSObject, let reference as NSObject):
      return value.isEqual(reference)
    default:
      return false
    }
  }
}
