import Foundation

/// The `/file` built-in path (docs/protocol.md 10절); the Swift copy of
/// android/.../protocol/FileTransfer.kt. One file to a peer whose user approves it.
/// The sender's messages are DATAs with ACK_REQ and `u8 op`; the receiver answers the
/// OFFER with REPLY DATAs carrying `u8 result`. A transfer is named by the msgId of its
/// OFFER (the transferId).
enum FileMessage {
  static let path = "/file"

  static let opOffer = 0
  static let opChunk = 1
  static let opCancel = 2

  // Replies to an OFFER.
  static let accepted = 0
  static let declined = 1
  /// The receiver's user canceled after accepting.
  static let canceled = 2
  /// The receiver couldn't store the file.
  static let failed = 3
  /// The receiver's user didn't answer in time.
  static let timeout = 4

  static let maxNameBytes = 255
  static let maxMimeBytes = 255

  /// Data per CHUNK; with its headers well inside maxMessageBytes.
  static let chunkSize = 16 * 1024

  /// A file extension kept when a long name is shortened, at most this long.
  private static let maxExtensionBytes = 16

  static let defaultMime = "application/octet-stream"

  enum Request {
    case offer(size: Int64, name: String, mime: String)
    case chunk(transferId: UInt32, offset: Int64, data: Data)
    case cancel(transferId: UInt32)
  }

  /// OFFER: `u64 size`, `u8 nameLen`, name, `u8 mimeLen`, mime.
  static func offer(size: Int64, name: String, mime: String) -> Data {
    let nameBytes = nameBytes(name)
    let mimeBytes = truncateUTF8(mime, maxBytes: maxMimeBytes)
    var writer = ByteWriter()
    writer.u8(opOffer)
    writer.u64(UInt64(bitPattern: size))
    writer.u8(nameBytes.count)
    writer.append(nameBytes)
    writer.u8(mimeBytes.count)
    writer.append(mimeBytes)
    return writer.data
  }

  /// CHUNK: `u32 transferId`, `u64 offset`, the data.
  static func chunk(transferId: UInt32, offset: Int64, data: Data) -> Data {
    var writer = ByteWriter()
    writer.u8(opChunk)
    writer.u32(transferId)
    writer.u64(UInt64(bitPattern: offset))
    writer.append(data)
    return writer.data
  }

  /// CANCEL: `u32 transferId`.
  static func cancel(transferId: UInt32) -> Data {
    var writer = ByteWriter()
    writer.u8(opCancel)
    writer.u32(transferId)
    return writer.data
  }

  /// Nil for an op this version doesn't know (answered UNSUPPORTED); throws
  /// `MalformedError` for a known op that doesn't decode. Bytes after an OFFER's
  /// fields are ignored, for later additions.
  static func decodeRequest(_ payload: Data) throws -> Request? {
    var reader = ByteReader(payload)
    switch try reader.u8() {
    case opOffer:
      let size = try reader.u64()
      let nameLength = try reader.u8()
      let name = String(decoding: try reader.take(nameLength), as: UTF8.self)
      let mimeLength = try reader.u8()
      let mime = String(decoding: try reader.take(mimeLength), as: UTF8.self)
      guard size <= UInt64(Int64.max), !name.isEmpty else { throw MalformedError("Bad OFFER") }
      return .offer(size: Int64(size), name: name, mime: mime)
    case opChunk:
      let transferId = try reader.u32()
      let offset = try reader.u64()
      let data = reader.rest()
      guard offset <= UInt64(Int64.max), !data.isEmpty else { throw MalformedError("Bad CHUNK") }
      return .chunk(transferId: transferId, offset: Int64(offset), data: data)
    case opCancel:
      return .cancel(transferId: try reader.u32())
    default:
      return nil
    }
  }

  static func reply(_ result: Int) -> Data { Data([UInt8(result)]) }

  static func decodeReply(_ payload: Data) -> Int? { payload.first.map { Int($0) } }

  /// `name` in at most `maxNameBytes` of UTF-8. A longer name keeps its extension
  /// (from the last '.', if that's at most `maxExtensionBytes`) and loses the end of
  /// the part before it.
  static func nameBytes(_ name: String) -> Data {
    let bytes = [UInt8](name.utf8)
    guard bytes.count > maxNameBytes else { return Data(bytes) }
    guard let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot > 0, bytes.count - dot <= maxExtensionBytes else {
      return truncateUTF8(name, maxBytes: maxNameBytes)
    }
    let extensionBytes = Data(bytes[dot...])
    let base = String(decoding: bytes[..<dot], as: UTF8.self)
    return truncateUTF8(base, maxBytes: maxNameBytes - extensionBytes.count) + extensionBytes
  }

  /// A name that's safe as one path component on this phone: no separators, control
  /// characters, or characters file systems reject, and no leading dots or spaces.
  static func safeFileName(_ name: String) -> String {
    let rejected = Set("/\\:*?\"<>|".unicodeScalars)
    var scalars = name.unicodeScalars.map { scalar -> Unicode.Scalar in
      scalar.value < 0x20 || scalar.value == 0x7F || rejected.contains(scalar) ? "_" : scalar
    }
    while let first = scalars.first, first == "." || first == " " {
      scalars.removeFirst()
    }
    while let last = scalars.last, last == " " {
      scalars.removeLast()
    }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    let cleaned = String(view)
    return cleaned.isEmpty ? "file" : cleaned
  }

  /// `mime` if it looks like `type/subtype` (lowercased), else `defaultMime`.
  static func safeMime(_ mime: String) -> String {
    let lower = mime.lowercased()
    let scalars = Array(lower.unicodeScalars)
    guard let slash = scalars.firstIndex(of: "/"), slash > 0, slash < scalars.count - 1,
      !scalars[(slash + 1)...].contains("/")
    else { return defaultMime }
    let symbols = Set("!#$&^_.+-".unicodeScalars)
    let valid = scalars.enumerated().allSatisfy { index, scalar in
      index == slash || (0x61...0x7A).contains(scalar.value) || (0x30...0x39).contains(scalar.value)
        || symbols.contains(scalar)
    }
    return valid ? lower : defaultMime
  }
}

enum TransferState {
  /// Receiving: waiting for this phone's user.
  case offered
  /// Sending: waiting for the peer's user.
  case waiting
  case transferring
  case completed
  case declined
  case canceled
  case failed

  var finished: Bool {
    switch self {
    case .offered, .waiting, .transferring: return false
    case .completed, .declined, .canceled, .failed: return true
    }
  }
}

/// Why a transfer failed (`FileTransfer.reason`; `fileTransfer.reason` on the channel).
enum TransferFailure {
  /// Nobody answered the offer in time, or the chunks stopped coming.
  static let timeout = "timeout"
  /// The peer's app has no `/file` (an older version).
  static let unsupported = "unsupported"
  /// A message couldn't be sent before its TTL ran out.
  static let notConnected = "notConnected"
  /// A message was sent, but its ACK never came.
  static let linkLost = "linkLost"
  /// This phone couldn't store the file.
  static let storage = "storage"
  /// This phone couldn't read the file.
  static let read = "read"
  /// The peer failed: couldn't store it, or answered something unexpected.
  static let peer = "peer"
  /// The peer has too many offers waiting.
  static let busy = "busy"
  /// The peer was removed, or removed this phone.
  static let unpaired = "unpaired"

  static func of(_ status: Int) -> String {
    switch status {
    case DeliveryStatus.noReceiver, DeliveryStatus.unsupported: return unsupported
    case DeliveryStatus.busy: return busy
    case DeliveryStatus.expiredNotSent: return notConnected
    case DeliveryStatus.expiredUnconfirmed: return linkLost
    default: return peer
    }
  }
}

/// Reads the file to send, front to back.
protocol FileSource: AnyObject {
  /// Up to `maxBytes` of the next bytes; empty at the end, nil on an error.
  func read(_ maxBytes: Int, _ done: @escaping (Data?) -> Void)

  func close()
}

/// Writes a received file, front to back.
protocol FileSink: AnyObject {
  func write(_ bytes: Data, _ done: @escaping (Bool) -> Void)

  /// All bytes are written; `done` gets the file's path, or nil on an error.
  func finish(_ done: @escaping (String?) -> Void)

  /// Deletes what was written.
  func abort()
}

protocol FileTransferHost: AnyObject {
  /// Where an accepted file goes; nil if it can't be stored.
  func createSink(_ transfer: FileTransfer) -> FileSink?

  /// `transfer` changed: its state, or its progress.
  func onTransferChanged(_ transfer: FileTransfer)
}

/// One file going to (`outgoing`) or coming from a peer. `id` is local to this phone.
final class FileTransfer {
  let id: Int64
  let peerId: PeerId
  let outgoing: Bool
  let name: String
  let size: Int64
  let mime: String

  /// The msgId of the OFFER; 0 until it's sent.
  fileprivate(set) var transferId: UInt32 = 0
  fileprivate(set) var state: TransferState
  /// Sending: bytes the peer confirmed. Receiving: bytes written.
  fileprivate(set) var bytes: Int64 = 0
  /// For `.declined` and `.canceled`: the peer's user did it.
  fileprivate(set) var byPeer = false
  /// For `.failed`: a `TransferFailure`.
  fileprivate(set) var reason: String?
  /// The delivery status behind a failure, if one was.
  fileprivate(set) var status: Int?
  /// Receiving, once `.completed`: where the file is.
  fileprivate(set) var path: String?

  fileprivate var source: FileSource?
  fileprivate var sink: FileSink?
  fileprivate var timer: Cancellable?
  /// Sending: bytes read and handed to the engine. Receiving: bytes given to the sink.
  fileprivate var nextOffset: Int64 = 0
  /// Sending: chunks waiting for their ACK.
  fileprivate var outstanding = 0
  fileprivate var reading = false

  init(id: Int64, peerId: PeerId, outgoing: Bool, name: String, size: Int64, mime: String) {
    self.id = id
    self.peerId = peerId
    self.outgoing = outgoing
    self.name = name
    self.size = size
    self.mime = mime
    state = outgoing ? .waiting : .offered
  }
}

/// The transfers over `/file` (docs/protocol.md 10절), both ways, on top of the engine's
/// delivery: the receiver's user approves an OFFER, then the sender keeps up to
/// `window` chunks in flight, each acknowledged once it's written. A short link loss is
/// covered by the engine resending within the TTL.
///
/// Like the engine, not thread-safe: the host calls it, and answers the `FileSource`
/// and `FileSink` callbacks, on the engine's thread.
final class FileTransfers {
  /// Chunks a sender keeps unacknowledged; leaves the engine room for others.
  static let window = 3
  /// How long the receiver's user has to answer an offer.
  static let answerTimeoutMs: Int64 = 120_000
  /// How long the sender waits for that answer; more, as the answer travels.
  static let senderAnswerTimeoutMs: Int64 = answerTimeoutMs + 10_000
  /// How long the receiver waits for the next chunk; over the chunks' TTL.
  static let idleTimeoutMs: Int64 = 90_000
  /// Offers and transfers from one peer, unfinished, before more get BUSY.
  static let maxIncomingPerPeer = 4

  private let engine: ProtocolEngine
  private let scheduler: EngineScheduler
  private unowned let host: FileTransferHost
  private var nextId: Int64 = 1
  private var transfers: [FileTransfer] = []

  init(engine: ProtocolEngine, scheduler: EngineScheduler, host: FileTransferHost) {
    self.engine = engine
    self.scheduler = scheduler
    self.host = host
  }

  subscript(id: Int64) -> FileTransfer? { transfers.first { $0.id == id } }

  /// The unfinished transfers, and received files nobody has dismissed.
  func all() -> [FileTransfer] { transfers }

  // MARK: - Sending

  /// Offers `source` to `peerId`; its user decides.
  @discardableResult
  func offer(peerId: PeerId, name: String, size: Int64, mime: String, source: FileSource) -> FileTransfer {
    let transfer = FileTransfer(id: nextId, peerId: peerId, outgoing: true, name: name, size: size, mime: mime)
    nextId += 1
    transfer.source = source
    transfers.append(transfer)
    host.onTransferChanged(transfer)
    // The ACK only says the offer arrived; the answer comes as a reply.
    let msgId = engine.send(
      peerId: peerId, path: FileMessage.path, payload: FileMessage.offer(size: size, name: name, mime: mime), replyTo: 0,
      ttlMs: 0, app: nil
    ) { [weak self] status in
      if status != DeliveryStatus.ok && transfer.state == .waiting {
        self?.fail(
          transfer, TransferFailure.of(status), status: status, notifyPeer: status == DeliveryStatus.expiredUnconfirmed)
      }
    }
    // A local failure can come before send returns.
    if !transfer.state.finished {
      transfer.transferId = msgId
      transfer.timer = scheduler.schedule(FileTransfers.senderAnswerTimeoutMs) { [weak self] in
        if transfer.state == .waiting {
          self?.fail(transfer, TransferFailure.timeout, notifyPeer: true)
        }
      }
    }
    return transfer
  }

  /// The peer's answer to one of our offers.
  func onReply(peerId: PeerId, data: DataEnvelope) {
    guard let transfer = transfers.first(where: { $0.outgoing && $0.peerId == peerId && $0.transferId == data.replyTo }),
      let result = FileMessage.decodeReply(data.payload)
    else { return }
    switch result {
    case FileMessage.accepted:
      guard transfer.state == .waiting else { return }
      transfer.timer?.cancel()
      transfer.timer = nil
      transfer.state = .transferring
      if transfer.size == 0 {
        finish(transfer, .completed)
      } else {
        host.onTransferChanged(transfer)
        pump(transfer)
      }
    case FileMessage.declined: finish(transfer, .declined, byPeer: true)
    case FileMessage.canceled: finish(transfer, .canceled, byPeer: true)
    case FileMessage.timeout: finish(transfer, .failed, reason: TransferFailure.timeout)
    default: finish(transfer, .failed, reason: TransferFailure.peer)
    }
  }

  private func pump(_ transfer: FileTransfer) {
    guard let source = transfer.source, transfer.state == .transferring, !transfer.reading,
      transfer.outstanding < FileTransfers.window, transfer.nextOffset < transfer.size
    else { return }
    transfer.reading = true
    let length = Int(min(Int64(FileMessage.chunkSize), transfer.size - transfer.nextOffset))
    source.read(length) { [weak self] read in
      guard let self else { return }
      transfer.reading = false
      guard transfer.state == .transferring else { return }
      guard let read, !read.isEmpty else {
        // An error, or the file got shorter than offered.
        self.fail(transfer, TransferFailure.read, notifyPeer: true)
        return
      }
      let data = read.count > length ? Data(read.prefix(length)) : read
      let offset = transfer.nextOffset
      transfer.nextOffset += Int64(data.count)
      transfer.outstanding += 1
      self.engine.send(
        peerId: transfer.peerId, path: FileMessage.path,
        payload: FileMessage.chunk(transferId: transfer.transferId, offset: offset, data: data), replyTo: 0,
        ttlMs: ProtocolEngine.maxTtlMs, app: nil, bulk: true
      ) { [weak self] status in self?.onChunkResult(transfer, data.count, status) }
      self.pump(transfer)
    }
  }

  private func onChunkResult(_ transfer: FileTransfer, _ length: Int, _ status: Int) {
    transfer.outstanding -= 1
    guard transfer.state == .transferring else { return }
    switch status {
    case DeliveryStatus.ok:
      transfer.bytes += Int64(length)
      if transfer.bytes >= transfer.size {
        finish(transfer, .completed)
      } else {
        host.onTransferChanged(transfer)
        pump(transfer)
      }
    case DeliveryStatus.denied:
      // The receiver dropped the transfer; its CANCELED reply may still be coming.
      finish(transfer, .canceled, byPeer: true)
    default:
      fail(transfer, TransferFailure.of(status), status: status, notifyPeer: true)
    }
  }

  // MARK: - Receiving

  /// A `/file` request from `peerId`; `done` gets the ACK status.
  func onRequest(peerId: PeerId, data: DataEnvelope, done: @escaping (Int) -> Void) {
    let request: FileMessage.Request?
    do {
      request = try FileMessage.decodeRequest(data.payload)
    } catch {
      done(DeliveryStatus.malformed)
      return
    }
    switch request {
    case nil:
      done(DeliveryStatus.unsupported)
    case .offer(let size, let name, let mime):
      onOffer(peerId: peerId, msgId: data.msgId, size: size, name: name, mime: mime, done: done)
    case .chunk(let transferId, let offset, let bytes):
      onChunk(peerId: peerId, transferId: transferId, offset: offset, data: bytes, done: done)
    case .cancel(let transferId):
      if let transfer = incoming(peerId, transferId) {
        finish(transfer, .canceled, byPeer: true)
      }
      done(DeliveryStatus.ok)
    }
  }

  private func incoming(_ peerId: PeerId, _ transferId: UInt32) -> FileTransfer? {
    transfers.first { !$0.outgoing && $0.peerId == peerId && $0.transferId == transferId }
  }

  private func onOffer(
    peerId: PeerId, msgId: UInt32, size: Int64, name: String, mime: String, done: @escaping (Int) -> Void
  ) {
    if incoming(peerId, msgId) != nil {
      done(DeliveryStatus.ok)
      return
    }
    let waiting = transfers.filter { !$0.outgoing && $0.peerId == peerId && !$0.state.finished }.count
    if waiting >= FileTransfers.maxIncomingPerPeer {
      done(DeliveryStatus.busy)
      return
    }
    let transfer = FileTransfer(
      id: nextId, peerId: peerId, outgoing: false, name: FileMessage.safeFileName(name), size: size,
      mime: FileMessage.safeMime(mime))
    nextId += 1
    transfer.transferId = msgId
    transfers.append(transfer)
    transfer.timer = scheduler.schedule(FileTransfers.answerTimeoutMs) { [weak self] in
      guard let self, transfer.state == .offered else { return }
      self.reply(transfer, FileMessage.timeout)
      self.finish(transfer, .failed, reason: TransferFailure.timeout)
    }
    done(DeliveryStatus.ok)
    host.onTransferChanged(transfer)
  }

  /// This phone's user answers the offer `id`.
  @discardableResult
  func respond(id: Int64, accept: Bool) -> Bool {
    guard let transfer = self[id], !transfer.outgoing, transfer.state == .offered else { return false }
    transfer.timer?.cancel()
    transfer.timer = nil
    if !accept {
      reply(transfer, FileMessage.declined)
      finish(transfer, .declined)
      return true
    }
    guard let sink = host.createSink(transfer) else {
      reply(transfer, FileMessage.failed)
      finish(transfer, .failed, reason: TransferFailure.storage)
      return true
    }
    transfer.sink = sink
    transfer.state = .transferring
    reply(transfer, FileMessage.accepted)
    if transfer.size == 0 {
      complete(transfer, sink) { _ in }
      return true
    }
    armIdleTimer(transfer)
    host.onTransferChanged(transfer)
    return true
  }

  private func onChunk(
    peerId: PeerId, transferId: UInt32, offset: Int64, data: Data, done: @escaping (Int) -> Void
  ) {
    guard let transfer = incoming(peerId, transferId), let sink = transfer.sink, transfer.state == .transferring else {
      done(DeliveryStatus.denied)
      return
    }
    let end = offset + Int64(data.count)
    if end <= transfer.nextOffset {
      // A retransmission of what we have.
      done(DeliveryStatus.ok)
      return
    }
    if offset != transfer.nextOffset || end > transfer.size {
      fail(transfer, TransferFailure.peer, status: DeliveryStatus.malformed, notifyPeer: true)
      done(DeliveryStatus.malformed)
      return
    }
    transfer.nextOffset = end
    armIdleTimer(transfer)
    sink.write(data) { [weak self] written in
      guard let self else { return }
      if transfer.state != .transferring {
        done(DeliveryStatus.denied)
      } else if !written {
        self.fail(transfer, TransferFailure.storage, notifyPeer: true)
        done(DeliveryStatus.error)
      } else {
        transfer.bytes += Int64(data.count)
        if transfer.bytes < transfer.size {
          done(DeliveryStatus.ok)
          self.host.onTransferChanged(transfer)
        } else {
          self.complete(transfer, sink, done)
        }
      }
    }
  }

  /// Every byte is written; the last chunk's ACK waits for the file to be closed.
  private func complete(_ transfer: FileTransfer, _ sink: FileSink, _ done: @escaping (Int) -> Void) {
    transfer.timer?.cancel()
    transfer.timer = nil
    sink.finish { [weak self] path in
      guard let self else { return }
      if transfer.state != .transferring {
        done(DeliveryStatus.denied)
      } else if let path {
        transfer.path = path
        self.finish(transfer, .completed)
        done(DeliveryStatus.ok)
      } else {
        self.fail(transfer, TransferFailure.storage, notifyPeer: true)
        done(DeliveryStatus.error)
      }
    }
  }

  private func armIdleTimer(_ transfer: FileTransfer) {
    transfer.timer?.cancel()
    transfer.timer = scheduler.schedule(FileTransfers.idleTimeoutMs) { [weak self] in
      if transfer.state == .transferring {
        self?.fail(transfer, TransferFailure.timeout, notifyPeer: true)
      }
    }
  }

  // MARK: - Both

  /// Stops the unfinished transfer `id`, telling the peer; an offer is declined.
  @discardableResult
  func cancel(id: Int64) -> Bool {
    guard let transfer = self[id], !transfer.state.finished else { return false }
    if transfer.state == .offered {
      return respond(id: id, accept: false)
    }
    if transfer.outgoing {
      sendCancel(transfer)
    } else {
      reply(transfer, FileMessage.canceled)
    }
    finish(transfer, .canceled)
    return true
  }

  /// Forgets the finished transfer `id` (a received file stays until dismissed).
  @discardableResult
  func dismiss(id: Int64) -> Bool {
    guard let transfer = self[id], transfer.state.finished else { return false }
    transfers.removeAll { $0 === transfer }
    return true
  }

  /// `peerId` is gone (removed, or it removed us); its unfinished transfers end.
  func peerRemoved(_ peerId: PeerId) {
    transfers.filter { $0.peerId == peerId && !$0.state.finished }.forEach {
      finish($0, .failed, reason: TransferFailure.unpaired)
    }
  }

  private func reply(_ transfer: FileTransfer, _ result: Int) {
    engine.send(
      peerId: transfer.peerId, path: FileMessage.path, payload: FileMessage.reply(result), replyTo: transfer.transferId,
      ttlMs: 0, app: nil
    ) { _ in }
  }

  private func sendCancel(_ transfer: FileTransfer) {
    guard transfer.transferId != 0 else { return }
    engine.send(
      peerId: transfer.peerId, path: FileMessage.path, payload: FileMessage.cancel(transferId: transfer.transferId),
      replyTo: 0, ttlMs: 0, app: nil
    ) { _ in }
  }

  /// Fails `transfer`; with `notifyPeer`, tells the peer to stop too.
  private func fail(_ transfer: FileTransfer, _ reason: String, status: Int? = nil, notifyPeer: Bool = false) {
    guard !transfer.state.finished else { return }
    if notifyPeer {
      if transfer.outgoing {
        sendCancel(transfer)
      } else {
        reply(transfer, FileMessage.failed)
      }
    }
    finish(transfer, .failed, reason: reason, status: status)
  }

  private func finish(
    _ transfer: FileTransfer, _ state: TransferState, reason: String? = nil, status: Int? = nil, byPeer: Bool = false
  ) {
    guard !transfer.state.finished else { return }
    transfer.state = state
    transfer.reason = reason
    transfer.status = status
    transfer.byPeer = byPeer
    transfer.timer?.cancel()
    transfer.timer = nil
    transfer.source?.close()
    transfer.source = nil
    if state != .completed {
      transfer.sink?.abort()
    }
    transfer.sink = nil
    // A received file waits for the user to save or share it (dismiss).
    if transfer.outgoing || state != .completed {
      transfers.removeAll { $0 === transfer }
    }
    host.onTransferChanged(transfer)
  }
}
