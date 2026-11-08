import Foundation

/// The Frame layer (docs/protocol.md 4절): one frame per ATT packet. A record is split
/// into frames that share a transfer id (tid), and frames of different tids may
/// interleave.
///
/// Header byte: bit7 S (first), bit6 E (last), bit0-5 tid. A first frame that isn't
/// also the last carries the record length (u32) after the header.
enum Frames {
  static let start = 0x80
  static let end = 0x40
  static let tidMask = 0x3F
  static let tidCount = 64

  /// Smallest frame size that still fits a first frame's header and a data byte.
  static let minFrameSize = 6

  /// Largest frame: an ATT attribute value is at most 512 bytes.
  static let maxFrameSize = 512

  /// The frame size for a link that can carry [packetLength] bytes per write or
  /// notification (ATT MTU - 3), at most [maxFrameSize].
  static func frameSize(packetLength: Int) -> Int {
    min(max(packetLength, minFrameSize), maxFrameSize)
  }

  /// Splits [record] into frames of at most [maxFrameSize] bytes.
  static func split(_ record: Data, tid: Int, maxFrameSize: Int) -> [Data] {
    precondition((0..<tidCount).contains(tid), "tid \(tid) out of range")
    precondition(maxFrameSize >= minFrameSize, "Frame size \(maxFrameSize) too small")
    let bytes = [UInt8](record)
    if bytes.count + 1 <= maxFrameSize {
      return [Data([UInt8(start | end | tid)] + bytes)]
    }
    var frames: [Data] = []
    let firstChunk = maxFrameSize - 5
    var first = ByteWriter()
    first.u8(start | tid)
    first.u32(UInt32(bytes.count))
    first.append(Data(bytes[0..<firstChunk]))
    frames.append(first.data)
    var offset = firstChunk
    while offset < bytes.count {
      let chunk = min(maxFrameSize - 1, bytes.count - offset)
      let last = offset + chunk == bytes.count
      frames.append(Data([UInt8((last ? end : 0) | tid)] + bytes[offset..<offset + chunk]))
      offset += chunk
    }
    return frames
  }
}

/// Reassembles the frames received on one link, with a buffer per tid. Frames that
/// break the rules drop that tid's buffer.
final class FrameReassembler {
  private struct Buffer {
    let length: Int
    var data: [UInt8] = []
  }

  private let maxRecordSize: Int
  private var buffers = [Buffer?](repeating: nil, count: Frames.tidCount)

  /// Frames dropped so far, for diagnostics.
  private(set) var dropped = 0

  init(maxRecordSize: Int) {
    self.maxRecordSize = maxRecordSize
  }

  /// Takes one frame; returns the record it completes, or nil.
  func accept(_ frame: Data) -> Data? {
    let bytes = [UInt8](frame)
    guard let header = bytes.first.map(Int.init) else { return drop(nil) }
    let tid = header & Frames.tidMask
    let isStart = header & Frames.start != 0
    let isEnd = header & Frames.end != 0
    if isStart {
      // A new start on a tid in progress abandons the old record.
      buffers[tid] = nil
      if isEnd {
        let record = Data(bytes[1...])
        return record.count <= maxRecordSize ? record : drop(tid)
      }
      guard bytes.count >= 5 else { return drop(tid) }
      var reader = ByteReader(frame, offset: 1)
      guard let length = try? reader.u32(), length <= maxRecordSize else { return drop(tid) }
      var buffer = Buffer(length: Int(length))
      buffer.data.append(contentsOf: bytes[5...])
      guard buffer.data.count <= buffer.length else { return drop(tid) }
      buffers[tid] = buffer
      return nil
    }
    // A continuation without a start.
    guard var buffer = buffers[tid] else { return drop(nil) }
    buffer.data.append(contentsOf: bytes[1...])
    guard buffer.data.count <= buffer.length else { return drop(tid) }
    guard isEnd else {
      buffers[tid] = buffer
      return nil
    }
    buffers[tid] = nil
    return buffer.data.count == buffer.length ? Data(buffer.data) : drop(nil)
  }

  /// Drops every partial record, e.g. when the link goes away.
  func reset() {
    buffers = [Buffer?](repeating: nil, count: Frames.tidCount)
  }

  private func drop(_ tid: Int?) -> Data? {
    if let tid {
      buffers[tid] = nil
    }
    dropped += 1
    return nil
  }
}
