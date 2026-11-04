import CompanionCore
import Foundation
import Testing

@Test func lateFramesAreDroppedUpToTheNextKeyFrame() {
  var backlog = CompanionMirror.Backlog(limit: 2)
  let frame = { (byte: UInt8) in Data([byte]) }
  // Once full, the frames are gone and a key frame is asked once.
  let asked = (1...4).map { backlog.add(frame(UInt8($0)), isKey: false) }
  #expect(asked == [false, false, true, false])
  let afterDrop = backlog.next()
  #expect(afterDrop == nil)
  let askedAgain = [backlog.add(frame(5), isKey: true), backlog.add(frame(6), isKey: false)]
  #expect(askedAgain == [false, false])
  let sent = [backlog.next(), backlog.next(), backlog.next()]
  #expect(sent == [frame(5), frame(6), nil])
}

@Test func aMessageIsItsLengthAndItsLine() {
  #expect(CompanionMirror.message("list") == Data([4]) + Data("list".utf8))
}
