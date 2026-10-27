import CompanionCore
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test("Only a phone the user's iCloud lists may use the direct channel")
func admission() {
  let records: [CompanionRecord] = [
    .device(CompanionDevice(endpointID: "phone-1", name: "iPhone", addedAt: now)),
    .mac(
      CompanionMac(
        installationID: "phone-2", name: "Mac", version: "1", buildLabel: "", online: true,
        lastSeen: now)),
  ]
  #expect(CompanionAdmission.admits("phone-1", among: records))
  // A Mac's identifier, or anything else in the zone, admits nobody.
  #expect(!CompanionAdmission.admits("phone-2", among: records))
  #expect(!CompanionAdmission.admits("stranger", among: records))
  #expect(!CompanionAdmission.admits("", among: records))
  #expect(!CompanionAdmission.admits("phone-1", among: []))
}

@Test("A frame cut anywhere reads whole, and one too long is refused")
func remoteFrames() throws {
  let messages: [RemoteMessage] = [
    .hello(protocolVersion: 1, deviceName: "iPhone"),
    .send(sessionID: "S", text: "Bonjour 👋"),
    .failure(.requestGone),
  ]
  let bytes = messages.map(RemoteFrame.encode).reduce(Data(), +)
  for chunk in [1, 3, 7, bytes.count] {
    var decoder = RemoteFrame.Decoder()
    var decoded: [RemoteMessage] = []
    var start = 0
    while start < bytes.count {
      let end = min(start + chunk, bytes.count)
      decoded += try decoder.append(bytes.subdata(in: start..<end))
      start = end
    }
    #expect(decoded == messages, "cut every \(chunk) bytes")
  }
  var decoder = RemoteFrame.Decoder()
  #expect(throws: RemoteFrame.Failure.self) {
    _ = try decoder.append(Data([0x7F, 0xFF, 0xFF, 0xFF]))
  }
}

@Test("Only the Mac's own addresses go through it, and come back as they were")
func macLocalAddresses() throws {
  for local in [
    "http://localhost:4000/a", "http://127.0.0.1:8080", "http://10.0.0.2", "http://192.168.1.4",
    "http://172.20.10.2:3000", "http://studio.local/x", "http://app.localhost",
  ] {
    let url = try #require(URL(string: local))
    #expect(RemoteWebAddress.isMacLocal(url), "\(local)")
    let proxied = RemoteWebAddress.proxied(url)
    #expect(proxied.scheme?.hasPrefix(RemoteWebAddress.proxiedPrefix) == true)
    #expect(RemoteWebAddress.unproxied(proxied) == url)
  }
  for remote in ["https://github.com", "http://172.32.0.1", "https://8.8.8.8"] {
    let url = try #require(URL(string: remote))
    #expect(!RemoteWebAddress.isMacLocal(url), "\(remote)")
    #expect(RemoteWebAddress.proxied(url) == url)
  }
  #expect(RemoteWebAddress.same("http://a/b/", "http://a/b#top"))
  #expect(!RemoteWebAddress.same("http://a/b", "http://a/c"))
}

@Test("A request of several questions travels whole, with one answer per question (#428)")
func severalQuestions() throws {
  let request = RemoteRequest(
    id: "R",
    questions: [
      RemoteQuestion(
        header: "Action", title: "What now?",
        choices: [RemoteChoice(id: "0", label: "Merge"), RemoteChoice(id: "1", label: "Wait")]),
      RemoteQuestion(
        header: "Checks", title: "Which checks?",
        choices: [
          RemoteChoice(id: "0", label: "Tests", detail: "swift test"),
          RemoteChoice(id: "1", label: "Lint"),
        ],
        allowsSeveral: true, allowsText: true),
    ])
  // The first question also said as protocol 1 does.
  #expect(request.title == "What now?")
  #expect(request.subject == "Action")
  #expect(request.choices.map(\.label) == ["Merge", "Wait"])
  #expect(!request.allowsSeveral)
  let messages: [RemoteMessage] = [
    .conversation(RemoteConversation(sessionID: "S", entries: [], request: request)),
    .answers(
      sessionID: "S", requestID: "R",
      answers: [RemoteAnswer(choiceIDs: ["1"]), RemoteAnswer(choiceIDs: ["0", "1"])]),
  ]
  var decoder = RemoteFrame.Decoder()
  #expect(try decoder.append(messages.map(RemoteFrame.encode).reduce(Data(), +)) == messages)
  #expect(request.shownQuestions.count == 2)
}

@Test("A request of protocol 1 shows its single question, and its Mac gets `answer`")
func protocolOneRequest() throws {
  let json = #"""
    {"id":"R","kind":"question","title":"Which?","subject":"Pick","choices":[{"id":"0","label":"A","isDestructive":false}],"allowsSeveral":true,"allowsText":false}
    """#
  let request = try JSONDecoder().decode(RemoteRequest.self, from: Data(json.utf8))
  #expect(request.questions.isEmpty)
  #expect(
    request.shownQuestions == [
      RemoteQuestion(
        header: "Pick", title: "Which?", choices: [RemoteChoice(id: "0", label: "A")],
        allowsSeveral: true)
    ])
  let permission = RemoteRequest(
    id: "P", kind: .permission, title: "", choices: [RemoteChoice(id: "allowOnce", label: "")])
  #expect(permission.shownQuestions.isEmpty)
  #expect(!CompanionRemote.takesAnswers(1))
  #expect(!CompanionRemote.takesAnswers(nil))
  #expect(CompanionRemote.takesAnswers(CompanionRemote.protocolVersion))
  // A message the decoder does not know — as `answers` is to a phone of protocol 1 — is skipped
  // rather than failing the stream.
  let unknown = Data(#"{"futureCase":{"x":1}}"#.utf8)
  var bytes = Data([0, 0, 0, UInt8(unknown.count)]) + unknown
  bytes.append(RemoteFrame.encode(.failure(.requestGone)))
  var decoder = RemoteFrame.Decoder()
  #expect(try decoder.append(bytes) == [.failure(.requestGone)])
}

@Test("An answer counts once it takes a choice or words")
func answerGiven() {
  #expect(RemoteAnswer(choiceIDs: ["0"]).isGiven)
  #expect(RemoteAnswer(choiceIDs: [], text: "Other").isGiven)
  #expect(!RemoteAnswer(choiceIDs: [], text: "  ").isGiven)
  #expect(!RemoteAnswer(choiceIDs: []).isGiven)
}
