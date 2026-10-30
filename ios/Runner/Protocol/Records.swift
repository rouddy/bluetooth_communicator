import Foundation

let protocolVersion = 1

/// Largest reassembled record this implementation accepts (HELLO maxMessageSize).
let maxMessageBytes = 65_536

/// The 16-byte public id an install generates once (docs/protocol.md 2절).
struct PeerId: Hashable, Comparable, CustomStringConvertible {
  static let size = 16

  let bytes: Data

  init(_ bytes: Data) {
    precondition(bytes.count == PeerId.size, "peerId must be \(PeerId.size) bytes")
    self.bytes = Data(bytes)
  }

  init?(string: String) {
    guard let uuid = UUID(uuidString: string) else { return nil }
    self.init(withUnsafeBytes(of: uuid.uuid) { Data($0) })
  }

  static func random() -> PeerId {
    var generator = SystemRandomNumberGenerator()
    return PeerId(Data((0..<size).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
  }

  /// Unsigned byte order; decides low/high for the link tie-break (9절).
  static func < (lhs: PeerId, rhs: PeerId) -> Bool {
    lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
  }

  /// The UUID form used on the platform channel; lowercase, like Android's.
  var description: String {
    var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    withUnsafeMutableBytes(of: &uuid) { $0.copyBytes(from: bytes) }
    return UUID(uuid: uuid).uuidString.lowercased()
  }
}

enum Platform {
  static let android = 1
  static let ios = 2
}

/// REJECT reasons (6.5).
enum RejectReason {
  static let unknownPeer = 1
  static let badMac = 2
  static let alreadyConnected = 3
  static let userRejected = 4
  static let timeout = 5
  static let cannotPrompt = 6
  static let commitMismatch = 7
  static let unsupportedVersion = 8

  /// Names for the platform channel (`peerRejected.reason`).
  static func name(_ reason: Int) -> String {
    switch reason {
    case unknownPeer: return "unknownPeer"
    case badMac: return "badMac"
    case alreadyConnected: return "alreadyConnected"
    case userRejected: return "userRejected"
    case timeout: return "timeout"
    case cannotPrompt: return "cannotPrompt"
    case commitMismatch: return "commitMismatch"
    case unsupportedVersion: return "unsupportedVersion"
    default: return "unknown(\(reason))"
    }
  }
}

struct Hello {
  var version: Int
  var peerId: PeerId
  var nonce: Data
  var name: String?
  var platform: Int?
  var appVersion: String?
  var maxMessageSize: UInt32?
  /// HELLO_p only: the nonce of the HELLO_c it answers (6.2).
  var nonceC: Data?
}

/// A record (5절). `sealed` carries an Envelope; the others are the plaintext handshake.
enum Record {
  case hello(Hello)
  case auth(mac: Data)
  case pairRequest
  case pairCommit(commit: Data)
  case pairKey(publicKey: Data)
  case pairConfirm(mac: Data)
  case reject(reason: Int)
  /// `body` is the ciphertext plus the tag.
  case sealed(counter: UInt32, body: Data)

  static let helloType = 0x01
  static let authType = 0x02
  static let pairRequestType = 0x03
  static let pairCommitType = 0x04
  static let pairKeyType = 0x05
  static let pairConfirmType = 0x06
  static let rejectType = 0x07
  static let sealedType = 0x10

  static let macSize = 32
  static let publicKeySize = 65
  static let nonceSize = 16
  static let gcmTagSize = 16
  static let maxNameBytes = 64

  private static let tagPeerId = 0x01
  private static let tagNonce = 0x02
  private static let tagName = 0x03
  private static let tagPlatform = 0x04
  private static let tagAppVersion = 0x05
  private static let tagMaxMessageSize = 0x06
  private static let tagNonceC = 0x07

  /// Bytes 0-5 of a SEALED record: the AES-GCM AAD.
  static func sealedHeader(counter: UInt32) -> Data {
    var writer = ByteWriter()
    writer.u8(protocolVersion)
    writer.u8(sealedType)
    writer.u32(counter)
    return writer.data
  }

  static func encode(_ record: Record) -> Data {
    var writer = ByteWriter()
    switch record {
    case .hello(let hello):
      writer.u8(hello.version)
      writer.u8(helloType)
      Tlv.put(&writer, tagPeerId, hello.peerId.bytes)
      Tlv.put(&writer, tagNonce, hello.nonce)
      if let name = hello.name {
        Tlv.put(&writer, tagName, truncateUTF8(name, maxBytes: maxNameBytes))
      }
      if let platform = hello.platform {
        Tlv.put(&writer, tagPlatform, Data([UInt8(platform)]))
      }
      if let appVersion = hello.appVersion {
        Tlv.put(&writer, tagAppVersion, Data(appVersion.utf8))
      }
      if let size = hello.maxMessageSize {
        var value = ByteWriter()
        value.u32(size)
        Tlv.put(&writer, tagMaxMessageSize, value.data)
      }
      if let nonceC = hello.nonceC {
        Tlv.put(&writer, tagNonceC, nonceC)
      }
    case .auth(let mac):
      writer.u8(protocolVersion)
      writer.u8(authType)
      writer.append(mac)
    case .pairRequest:
      writer.u8(protocolVersion)
      writer.u8(pairRequestType)
    case .pairCommit(let commit):
      writer.u8(protocolVersion)
      writer.u8(pairCommitType)
      writer.append(commit)
    case .pairKey(let publicKey):
      writer.u8(protocolVersion)
      writer.u8(pairKeyType)
      writer.append(publicKey)
    case .pairConfirm(let mac):
      writer.u8(protocolVersion)
      writer.u8(pairConfirmType)
      writer.append(mac)
    case .reject(let reason):
      writer.u8(protocolVersion)
      writer.u8(rejectType)
      writer.u8(reason)
    case .sealed(let counter, let body):
      writer.u8(protocolVersion)
      writer.u8(sealedType)
      writer.u32(counter)
      writer.append(body)
    }
    return writer.data
  }

  /// Records of other versions than v1 (except HELLO) are malformed.
  static func decode(_ data: Data) throws -> Record {
    var reader = ByteReader(data)
    let version = try reader.u8()
    let type = try reader.u8()
    if type != helloType && version != protocolVersion {
      throw MalformedError("Unsupported record version \(version)")
    }
    switch type {
    case helloType: return .hello(try decodeHello(version: version, reader: &reader))
    case authType: return .auth(mac: try exact(&reader, macSize))
    case pairRequestType:
      try end(reader)
      return .pairRequest
    case pairCommitType: return .pairCommit(commit: try exact(&reader, macSize))
    case pairKeyType: return .pairKey(publicKey: try exact(&reader, publicKeySize))
    case pairConfirmType: return .pairConfirm(mac: try exact(&reader, macSize))
    case rejectType:
      let reason = try reader.u8()
      try end(reader)
      return .reject(reason: reason)
    case sealedType:
      let counter = try reader.u32()
      guard reader.remaining >= gcmTagSize else { throw MalformedError("SEALED shorter than its tag") }
      return .sealed(counter: counter, body: reader.rest())
    default:
      throw MalformedError("Unknown record type \(type)")
    }
  }

  private static func decodeHello(version: Int, reader: inout ByteReader) throws -> Hello {
    var peerId: PeerId?
    var nonce: Data?
    var hello = Hello(version: version, peerId: PeerId(Data(count: PeerId.size)), nonce: Data())
    try Tlv.read(&reader) { tag, value in
      switch tag {
      case tagPeerId: peerId = PeerId(try requireSize(value, PeerId.size))
      case tagNonce: nonce = try requireSize(value, nonceSize)
      case tagName: hello.name = String(decoding: value, as: UTF8.self)
      case tagPlatform: hello.platform = Int(try requireSize(value, 1)[0])
      case tagAppVersion: hello.appVersion = String(decoding: value, as: UTF8.self)
      case tagMaxMessageSize:
        var size = ByteReader(try requireSize(value, 4))
        hello.maxMessageSize = try size.u32()
      case tagNonceC: hello.nonceC = try requireSize(value, nonceSize)
      default: break
      }
    }
    guard let peerId else { throw MalformedError("HELLO without peerId") }
    guard let nonce else { throw MalformedError("HELLO without nonce") }
    hello.peerId = peerId
    hello.nonce = nonce
    return hello
  }

  private static func exact(_ reader: inout ByteReader, _ size: Int) throws -> Data {
    let value = try reader.take(size)
    try end(reader)
    return value
  }

  private static func end(_ reader: ByteReader) throws {
    if reader.remaining != 0 {
      throw MalformedError("\(reader.remaining) trailing bytes")
    }
  }
}

func requireSize(_ data: Data, _ size: Int) throws -> Data {
  guard data.count == size else { throw MalformedError("Expected \(size) bytes, got \(data.count)") }
  return Data(data)
}

/// `u8 tag, u16 len, value[len]`, repeated; HELLO and CAPS use it.
enum Tlv {
  static func put(_ writer: inout ByteWriter, _ tag: Int, _ value: Data) {
    precondition(value.count <= 0xFFFF, "TLV value too long")
    writer.u8(tag)
    writer.u16(value.count)
    writer.append(value)
  }

  /// Calls [onEntry] for each entry; callers skip tags they don't know.
  static func read(_ reader: inout ByteReader, _ onEntry: (Int, Data) throws -> Void) throws {
    while reader.remaining > 0 {
      let tag = try reader.u8()
      let length = try reader.u16()
      try onEntry(tag, try reader.take(length))
    }
  }
}
