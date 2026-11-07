import CoreMedia
import Foundation

extension CompanionMirror {
  /// A bridge's frames as samples a display layer shows, the same on the Mac and on the phone.
  /// A frame is a `u8` set for a key frame, then for a key frame its SPS and PPS each after a
  /// `u16` length, then the picture in AVCC.
  public struct FrameDecoder {
    private var format: CMVideoFormatDescription?
    /// The picture's size, known from the first key frame on.
    public private(set) var size: CGSize?

    public init() {}

    /// `nil` for a frame that cannot be shown: one before the first key frame, or after a key
    /// frame that could not be read, until the next.
    public mutating func sample(from frame: Data) -> CMSampleBuffer? {
      guard let isKey = frame.first else { return nil }
      var offset = frame.startIndex + 1
      if isKey != 0 {
        guard let sets = Self.parameterSets(in: frame, offset: &offset),
          let made = Self.format(sps: sets.sps, pps: sets.pps)
        else {
          format = nil
          return nil
        }
        format = made
        let dimensions = CMVideoFormatDescriptionGetDimensions(made)
        size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
      }
      guard let format else { return nil }
      return Self.sample(frame.subdata(in: offset..<frame.endIndex), format: format)
    }

    private static func parameterSets(in frame: Data, offset: inout Int) -> (sps: Data, pps: Data)?
    {
      func next(_ offset: inout Int) -> Data? {
        guard frame.endIndex >= offset + 2 else { return nil }
        let length = Int(frame[offset]) << 8 | Int(frame[offset + 1])
        offset += 2
        guard length > 0, frame.endIndex >= offset + length else { return nil }
        defer { offset += length }
        return frame.subdata(in: offset..<offset + length)
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
      guard !data.isEmpty else { return nil }
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
      // No timing: each frame is shown as soon as it comes.
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
}
