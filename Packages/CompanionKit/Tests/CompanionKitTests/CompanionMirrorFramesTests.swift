import CompanionCore
import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox

@Suite("Mirror frames")
struct CompanionMirrorFramesTests {
  @Test("A key frame gives the picture's size and a sample, and the frames after it too")
  func keyFrame() throws {
    let (key, picture) = try Self.encodedFrames(width: 64, height: 48)
    var decoder = CompanionMirror.FrameDecoder()
    #expect(decoder.sample(from: key) != nil)
    #expect(decoder.size == CGSize(width: 64, height: 48))
    #expect(decoder.sample(from: Data([0]) + picture) != nil)
  }

  @Test("Nothing is shown before the first key frame, nor after one that cannot be read")
  func beforeAKeyFrame() throws {
    let (key, picture) = try Self.encodedFrames(width: 64, height: 48)
    var decoder = CompanionMirror.FrameDecoder()
    #expect(decoder.sample(from: Data()) == nil)
    #expect(decoder.sample(from: Data([0]) + picture) == nil)
    #expect(decoder.sample(from: key) != nil)
    #expect(decoder.sample(from: Data([1, 0, 9, 1])) == nil)
    #expect(decoder.sample(from: Data([0]) + picture) == nil)
  }

  /// One frame encoded as the bridges encode: a key frame as they write it, and its picture alone.
  private static func encodedFrames(width: Int, height: Int) throws -> (key: Data, picture: Data) {
    var session: VTCompressionSession?
    try #require(
      VTCompressionSessionCreate(
        allocator: nil, width: Int32(width), height: Int32(height),
        codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
        compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
        compressionSessionOut: &session) == noErr)
    let encoder = try #require(session)
    defer { VTCompressionSessionInvalidate(encoder) }
    var pixels: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixels)
    let image = try #require(pixels)
    nonisolated(unsafe) var encoded: CMSampleBuffer?
    VTCompressionSessionEncodeFrame(
      encoder, imageBuffer: image, presentationTimeStamp: .zero, duration: .invalid,
      frameProperties: nil, infoFlagsOut: nil
    ) { _, _, sample in encoded = sample }
    VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
    let sample = try #require(encoded)
    let format = try #require(CMSampleBufferGetFormatDescription(sample))
    var key = Data([1])
    for index in 0..<2 {
      var pointer: UnsafePointer<UInt8>?
      var count = 0
      try #require(
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
          format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
          parameterSetSizeOut: &count, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
          == noErr)
      key += Data([UInt8(count >> 8), UInt8(count & 0xff)])
      key += Data(bytes: try #require(pointer), count: count)
    }
    let block = try #require(CMSampleBufferGetDataBuffer(sample))
    var picture = Data(count: CMBlockBufferGetDataLength(block))
    picture.withUnsafeMutableBytes {
      _ = CMBlockBufferCopyDataBytes(
        block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
    }
    return (key + picture, picture)
  }
}
