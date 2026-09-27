import Compression
import Foundation
import VibeApplication
import VibePersistence

/// Reads the plain files of a zip archive that came from anywhere (#41).
///
/// Nothing is extracted to disk and no tool is run: the central directory is read first, every
/// entry is checked — its name, its kind, its sizes as declared — and only then is anything
/// inflated, into a buffer no larger than the size declared. What does not fit the bounds refuses
/// the whole archive: an avatar is a dozen small images, and anything else is not one.
enum ZipArchiveReader {
  struct Limits {
    var archiveBytes = 30 * 1024 * 1024
    var entries = 64
    var entryBytes = 25 * 1024 * 1024
    var totalBytes = 100 * 1024 * 1024
  }

  /// A file of the archive: its name, without the folder every entry may share, and its bytes.
  struct Entry: Equatable {
    let name: String
    let contents: Data
  }

  /// The plain files of the archive, `__MACOSX` and `.DS_Store` left out.
  static func entries(of data: Data, limits: Limits = Limits()) throws -> [Entry] {
    guard data.count <= limits.archiveBytes else { throw AvatarProblem.archiveTooLarge }
    let bytes = [UInt8](data)
    let directory = try centralDirectory(of: bytes)
    guard directory.count <= limits.entries else { throw AvatarProblem.archiveTooLarge }

    // Every name checked before anything is read.
    var records: [(record: Record, components: [String])] = []
    var total = 0
    for record in directory {
      let components = try components(of: record)
      if components.first == "__MACOSX" || components.last == ".DS_Store" { continue }
      if record.isDirectory { continue }
      guard !record.isSymbolicLink, record.isRegularFile else {
        throw AvatarProblem.archiveUnsafeEntry(record.name)
      }
      guard !record.isEncrypted else { throw AvatarProblem.archiveEncrypted }
      guard record.method == 0 || record.method == 8 else {
        throw AvatarProblem.archiveUnreadable
      }
      guard record.uncompressedSize <= limits.entryBytes else {
        throw AvatarProblem.archiveTooLarge
      }
      total += record.uncompressedSize
      guard total <= limits.totalBytes else { throw AvatarProblem.archiveTooLarge }
      records.append((record, components))
    }

    // One folder at the root, which many tools add, is accepted; any other folder is not.
    let roots = Set(records.map { $0.components.count > 1 ? $0.components[0] : "" })
    let sharedRoot = roots.count == 1 && roots.first != "" ? roots.first : nil
    var result: [Entry] = []
    for (record, components) in records {
      let relative = sharedRoot == nil ? components : Array(components.dropFirst())
      guard relative.count == 1 else { throw AvatarProblem.archiveUnsafeEntry(record.name) }
      result.append(Entry(name: relative[0], contents: try contents(of: record, in: bytes)))
    }
    return result
  }

  // MARK: - Directory

  struct Record {
    let name: String
    let flags: UInt16
    let method: UInt16
    let crc: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let externalAttributes: UInt32
    let madeBy: UInt16
    let localHeaderOffset: Int

    var isEncrypted: Bool { flags & 1 != 0 }
    var isDirectory: Bool { name.hasSuffix("/") }
    /// The Unix mode, when the archive was made on Unix.
    var mode: UInt32? { madeBy >> 8 == 3 ? externalAttributes >> 16 : nil }
    var isSymbolicLink: Bool { mode.map { $0 & 0o170000 == 0o120000 } ?? false }
    /// No mode, or a regular file's.
    var isRegularFile: Bool {
      mode.map { $0 & 0o170000 == 0 || $0 & 0o170000 == 0o100000 } ?? true
    }
  }

  static func centralDirectory(of bytes: [UInt8]) throws -> [Record] {
    // The end of central directory record: 22 bytes, followed by a comment of at most 65 535.
    guard bytes.count >= 22 else { throw AvatarProblem.archiveUnreadable }
    let lowest = max(0, bytes.count - 22 - 65_535)
    var end: Int?
    var position = bytes.count - 22
    while position >= lowest {
      if read32(bytes, position) == 0x0605_4B50 {
        end = position
        break
      }
      position -= 1
    }
    guard let end else { throw AvatarProblem.archiveUnreadable }
    let count = Int(read16(bytes, end + 10))
    let size = Int(read32(bytes, end + 12))
    let offset = Int(read32(bytes, end + 16))
    // Zip64 marks its sizes with all ones: not an avatar's.
    guard count != 0xFFFF, offset != 0xFFFF_FFFF, offset + size <= end else {
      throw AvatarProblem.archiveUnreadable
    }
    var records: [Record] = []
    var cursor = offset
    for _ in 0..<count {
      guard cursor + 46 <= end, read32(bytes, cursor) == 0x0201_4B50 else {
        throw AvatarProblem.archiveUnreadable
      }
      let nameLength = Int(read16(bytes, cursor + 28))
      let extraLength = Int(read16(bytes, cursor + 30))
      let commentLength = Int(read16(bytes, cursor + 32))
      let nameEnd = cursor + 46 + nameLength
      guard nameEnd <= end else { throw AvatarProblem.archiveUnreadable }
      guard let name = String(bytes: bytes[(cursor + 46)..<nameEnd], encoding: .utf8) else {
        throw AvatarProblem.archiveUnreadable
      }
      records.append(
        Record(
          name: name, flags: read16(bytes, cursor + 8), method: read16(bytes, cursor + 10),
          crc: read32(bytes, cursor + 16), compressedSize: Int(read32(bytes, cursor + 20)),
          uncompressedSize: Int(read32(bytes, cursor + 24)),
          externalAttributes: read32(bytes, cursor + 38), madeBy: read16(bytes, cursor + 4),
          localHeaderOffset: Int(read32(bytes, cursor + 42))))
      cursor = nameEnd + extraLength + commentLength
    }
    return records
  }

  /// The parts of an entry's name; any that could lead out of the folder refuses the archive.
  static func components(of record: Record) throws -> [String] {
    let name = record.name
    guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
      !name.unicodeScalars.contains(where: { $0.value < 0x20 })
    else { throw AvatarProblem.archiveUnsafeEntry(name) }
    let components = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.isEmpty, !components.contains(where: { $0 == ".." || $0 == "." }) else {
      throw AvatarProblem.archiveUnsafeEntry(name)
    }
    return components
  }

  // MARK: - Contents

  static func contents(of record: Record, in bytes: [UInt8]) throws -> Data {
    let header = record.localHeaderOffset
    guard header + 30 <= bytes.count, read32(bytes, header) == 0x0403_4B50 else {
      throw AvatarProblem.archiveUnreadable
    }
    let start = header + 30 + Int(read16(bytes, header + 26)) + Int(read16(bytes, header + 28))
    let end = start + record.compressedSize
    guard start <= end, end <= bytes.count else { throw AvatarProblem.archiveUnreadable }
    let data: Data
    if record.method == 0 {
      guard record.compressedSize == record.uncompressedSize else {
        throw AvatarProblem.archiveUnreadable
      }
      data = Data(bytes[start..<end])
    } else {
      data = try inflate(Array(bytes[start..<end]), size: record.uncompressedSize)
    }
    guard CRC32.checksum(data) == record.crc else { throw AvatarProblem.archiveUnreadable }
    return data
  }

  /// Raw DEFLATE into a buffer of the size declared, and not a byte more: an entry that inflates
  /// past what it declared is refused, not allocated.
  static func inflate(_ source: [UInt8], size: Int) throws -> Data {
    guard size > 0 else { return Data() }
    var destination = [UInt8](repeating: 0, count: size + 1)
    let written = destination.withUnsafeMutableBufferPointer { target -> Int in
      source.withUnsafeBufferPointer { input -> Int in
        guard let output = target.baseAddress, let compressed = input.baseAddress else { return -1 }
        return compression_decode_buffer(
          output, target.count, compressed, input.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard written == size else { throw AvatarProblem.archiveUnreadable }
    return Data(destination[0..<size])
  }

  static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    guard offset + 2 <= bytes.count else { return 0 }
    return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }

  static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    guard offset + 4 <= bytes.count else { return 0 }
    return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }
}
