import Foundation

/// An app identity: package name plus the SHA-256 of its signing certificate(s) (8절).
struct AppIdentity: Hashable {
  let packageName: String
  /// 32 bytes, lowercase hex.
  let certHash: String
}

/// ACK statuses (7절) and the sender-local results (9절).
enum DeliveryStatus {
  static let ok = 0
  static let noReceiver = 1
  static let unsupported = 2
  static let tooLarge = 3
  static let busy = 4
  static let denied = 5
  static let malformed = 6
  static let error = 255
  /// Not sent before the TTL ran out; safe to retry.
  static let expiredNotSent = 1000
  /// Sent, but no ACK arrived; the peer may have received it.
  static let expiredUnconfirmed = 1001
}

struct DataEnvelope {
  var msgId: UInt32
  var flags: Int
  var path: String
  /// The request this answers when `Envelope.flagReply` is set, otherwise 0.
  var replyTo: UInt32
  var payload: Data

  var isReply: Bool { flags & Envelope.flagReply != 0 }
}

/// The plaintext of a SEALED record (7절).
enum Envelope {
  case data(DataEnvelope)
  case ack(refMsgId: UInt32, status: Int)
  case caps(msgId: UInt32, builtins: [String], apps: [AppIdentity])
  case unpair(msgId: UInt32)
  /// A type this version doesn't know; answered with UNSUPPORTED if it asks for an ACK.
  case unknown(type: Int, msgId: UInt32, flags: Int)

  static let dataType = 0x01
  static let ackType = 0x02
  static let capsType = 0x03
  static let unpairType = 0x04

  static let flagAckReq = 0x01
  static let flagReply = 0x02
  static let maxPathBytes = 255

  private static let capsTagBuiltin = 0x01
  private static let capsTagApp = 0x02

  var msgId: UInt32 {
    switch self {
    case .data(let data): return data.msgId
    case .ack: return 0
    case .caps(let msgId, _, _), .unpair(let msgId), .unknown(_, let msgId, _): return msgId
    }
  }

  var flags: Int {
    switch self {
    case .data(let data): return data.flags
    case .ack, .caps: return 0
    case .unpair: return Envelope.flagAckReq
    case .unknown(_, _, let flags): return flags
    }
  }

  var ackRequested: Bool { flags & Envelope.flagAckReq != 0 }

  static func encode(_ envelope: Envelope) -> Data {
    var writer = ByteWriter()
    let type: Int
    switch envelope {
    case .data: type = dataType
    case .ack: type = ackType
    case .caps: type = capsType
    case .unpair: type = unpairType
    case .unknown(let unknownType, _, _): type = unknownType
    }
    writer.u8(type)
    writer.u8(envelope.flags)
    writer.u32(envelope.msgId)
    switch envelope {
    case .data(let data):
      let path = Data(data.path.utf8)
      precondition(path.count <= maxPathBytes, "Path longer than \(maxPathBytes) bytes")
      writer.u8(path.count)
      writer.append(path)
      if data.isReply {
        writer.u32(data.replyTo)
      }
      writer.append(data.payload)
    case .ack(let refMsgId, let status):
      writer.u32(refMsgId)
      writer.u8(status)
    case .caps(_, let builtins, let apps):
      builtins.forEach { Tlv.put(&writer, capsTagBuiltin, Data($0.utf8)) }
      for app in apps {
        var value = ByteWriter()
        let name = Data(app.packageName.utf8)
        value.u8(name.count)
        value.append(name)
        value.append(Data(hex: app.certHash) ?? Data(count: 32))
        Tlv.put(&writer, capsTagApp, value.data)
      }
    case .unpair, .unknown:
      break
    }
    return writer.data
  }

  static func decode(_ bytes: Data) throws -> Envelope {
    var reader = ByteReader(bytes)
    let type = try reader.u8()
    let flags = try reader.u8()
    let msgId = try reader.u32()
    switch type {
    case dataType:
      let pathLength = try reader.u8()
      let path = String(decoding: try reader.take(pathLength), as: UTF8.self)
      let replyTo = flags & flagReply != 0 ? try reader.u32() : 0
      return .data(DataEnvelope(msgId: msgId, flags: flags, path: path, replyTo: replyTo, payload: reader.rest()))
    case ackType:
      let ref = try reader.u32()
      return .ack(refMsgId: ref, status: try reader.u8())
    case capsType:
      var builtins: [String] = []
      var apps: [AppIdentity] = []
      try Tlv.read(&reader) { tag, value in
        switch tag {
        case capsTagBuiltin:
          builtins.append(String(decoding: value, as: UTF8.self))
        case capsTagApp:
          var app = ByteReader(value)
          let nameLength = try app.u8()
          let name = String(decoding: try app.take(nameLength), as: UTF8.self)
          apps.append(AppIdentity(packageName: name, certHash: try app.take(32).hex))
        default:
          break
        }
      }
      return .caps(msgId: msgId, builtins: builtins, apps: apps)
    case unpairType:
      return .unpair(msgId: msgId)
    default:
      return .unknown(type: type, msgId: msgId, flags: flags)
    }
  }
}
