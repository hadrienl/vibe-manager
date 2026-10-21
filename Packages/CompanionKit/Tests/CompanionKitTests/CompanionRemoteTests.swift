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
