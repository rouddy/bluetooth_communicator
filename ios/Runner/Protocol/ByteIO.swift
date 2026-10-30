import Foundation

/// Bytes that don't decode as the expected structure.
struct MalformedError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

/// Writes little-endian integers (docs/protocol.md 1절).
struct ByteWriter {
  private(set) var buffer: [UInt8] = []

  var data: Data { Data(buffer) }

  mutating func u8(_ value: Int) {
    buffer.append(UInt8(truncatingIfNeeded: value))
  }

  mutating func u16(_ value: Int) {
    u8(value)
    u8(value >> 8)
  }

  mutating func u32(_ value: UInt32) {
    for shift in stride(from: 0, to: 32, by: 8) {
      buffer.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
    }
  }

  mutating func append(_ data: Data) {
    buffer.append(contentsOf: data)
  }
}

struct ByteReader {
  private let buffer: [UInt8]
  private var position: Int

  init(_ data: Data, offset: Int = 0) {
    buffer = [UInt8](data)
    position = offset
  }

  var remaining: Int { buffer.count - position }

  mutating func u8() throws -> Int {
    try need(1)
    defer { position += 1 }
    return Int(buffer[position])
  }

  mutating func u16() throws -> Int {
    let low = try u8()
    return low | (try u8() << 8)
  }

  mutating func u32() throws -> UInt32 {
    var value: UInt32 = 0
    for shift in stride(from: 0, to: 32, by: 8) {
      value |= UInt32(try u8()) << UInt32(shift)
    }
    return value
  }

  mutating func take(_ count: Int) throws -> Data {
    try need(count)
    defer { position += count }
    return Data(buffer[position..<position + count])
  }

  mutating func rest() -> Data {
    defer { position = buffer.count }
    return Data(buffer[position...])
  }

  private func need(_ count: Int) throws {
    if count < 0 || remaining < count {
      throw MalformedError("Needed \(count) bytes, \(remaining) left")
    }
  }
}

extension Data {
  var hex: String { map { String(format: "%02x", $0) }.joined() }

  init?(hex: String) {
    guard hex.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    self.init(bytes)
  }
}

/// Cuts [text] to at most [maxBytes] of UTF-8 without splitting a character.
func truncateUTF8(_ text: String, maxBytes: Int) -> Data {
  let bytes = [UInt8](text.utf8)
  guard bytes.count > maxBytes else { return Data(bytes) }
  var end = maxBytes
  // Back up over continuation bytes (10xxxxxx) to the start of the cut character.
  while end > 0 && bytes[end] & 0xC0 == 0x80 {
    end -= 1
  }
  return Data(bytes[0..<end])
}
