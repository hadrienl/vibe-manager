import VibeApplication

// Bounded replay buffer. Output is kept as the blocks in which it was read so that trimming
// drops whole blocks from the front instead of copying megabytes on every append.
struct TerminalHistory {
  private struct Block {
    let bytes: [UInt8]
    let newlineCount: Int
  }

  private let limits: TerminalScrollbackLimits
  private var blocks: [Block] = []
  private var head = 0
  private var byteCount = 0
  private var newlineCount = 0
  private(set) var droppedByteCount = 0
  /// Every byte ever appended, trimmed or not: where the stream stands (#248). Bytes lost before
  /// they reached this buffer are not counted — nobody was shown them.
  private(set) var appendedByteCount = 0

  init(limits: TerminalScrollbackLimits) {
    self.limits = limits
  }

  var snapshot: TerminalHistorySnapshot {
    var bytes = [UInt8]()
    bytes.reserveCapacity(byteCount)
    for block in blocks[head...] {
      bytes.append(contentsOf: block.bytes)
    }
    return TerminalHistorySnapshot(
      bytes: bytes, droppedByteCount: droppedByteCount,
      startOffset: appendedByteCount - bytes.count)
  }

  /// Memory held by the blocks still in the history, which the budget only bounds while each block
  /// is stored at its own size.
  var storageByteCount: Int {
    blocks[head...].reduce(0) { $0 + $1.bytes.capacity }
  }

  /// Output that never reached this buffer at all — trimmed from another one before it was copied
  /// here — still counts as lost, and the snapshot has to say so.
  mutating func noteDropped(_ byteCount: Int) {
    droppedByteCount += max(0, byteCount)
  }

  @discardableResult
  mutating func append(_ bytes: [UInt8]) -> Int {
    guard !bytes.isEmpty else { return 0 }

    let newlines = bytes.reduce(into: 0) { total, byte in
      if byte == UInt8(ascii: "\n") { total += 1 }
    }
    // The budget counts bytes, not the storage behind them: a block kept with a buffer sized for a
    // much larger read would let the history weigh many times its limit.
    let stored = bytes.capacity > 2 * bytes.count ? bytes.withUnsafeBufferPointer(Array.init) : bytes
    blocks.append(Block(bytes: stored, newlineCount: newlines))
    byteCount += bytes.count
    newlineCount += newlines
    appendedByteCount += bytes.count

    let droppedNow = trim()
    droppedByteCount += droppedNow
    compactIfNeeded()
    return droppedNow
  }

  private mutating func trim() -> Int {
    var dropped = 0
    // The most recent block is never dropped: it holds what the user is looking at, even when a
    // single unterminated line is larger than the byte budget on its own.
    while head < blocks.count - 1,
      byteCount > limits.maximumByteCount || newlineCount > limits.maximumLineCount
    {
      let block = blocks[head]
      byteCount -= block.bytes.count
      newlineCount -= block.newlineCount
      dropped += block.bytes.count
      blocks[head] = Block(bytes: [], newlineCount: 0)
      head += 1
    }
    return dropped
  }

  private mutating func compactIfNeeded() {
    guard head > 128 else { return }
    blocks.removeFirst(head)
    head = 0
  }
}
