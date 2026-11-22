import XCTest

@testable import Runner

/// A file read from memory; `failAt` makes reads from that offset fail.
final class MemorySource: FileSource {
  private let data: Data
  private var position = 0
  var failAt: Int?
  var closed = false

  init(_ data: Data) {
    self.data = data
  }

  func read(_ maxBytes: Int, _ done: @escaping (Data?) -> Void) {
    if let failAt, position >= failAt {
      done(nil)
      return
    }
    let end = min(data.count, position + maxBytes)
    let chunk = data.subdata(in: position..<end)
    position = end
    done(chunk)
  }

  func close() {
    closed = true
  }
}

/// One phone's transfers, with files in memory.
final class Files: FileTransferHost {
  struct Change: Equatable {
    let state: TransferState
    let bytes: Int64
  }

  private final class MemorySink: FileSink {
    unowned let files: Files
    let transfer: FileTransfer

    init(files: Files, transfer: FileTransfer) {
      self.files = files
      self.transfer = transfer
    }

    func write(_ bytes: Data, _ done: @escaping (Bool) -> Void) {
      let id = transfer.id
      let write = { [unowned files] in
        files.stored[id, default: Data()].append(bytes)
        done(true)
      }
      if files.holdWrites {
        files.heldWrites.append(write)
      } else {
        write()
      }
    }

    func finish(_ done: @escaping (String?) -> Void) { done("/received/\(transfer.name)") }

    func abort() {
      files.aborted.append(transfer.id)
    }
  }

  private(set) var transfers: FileTransfers!
  var changes: [Change] = []
  var stored: [Int64: Data] = [:]
  var aborted: [Int64] = []
  var storable = true
  /// Holds each write in `heldWrites` instead of finishing it.
  var holdWrites = false
  var heldWrites: [() -> Void] = []

  init(_ phone: Phone, _ scheduler: FakeScheduler) {
    transfers = FileTransfers(engine: phone.engine, scheduler: scheduler, host: self)
    phone.caps = Capabilities(builtins: [FileMessage.path], apps: [testApp])
    phone.handler = { [unowned self] peerId, data, done in
      guard data.path == FileMessage.path else { return false }
      if data.isReply {
        self.transfers.onReply(peerId: peerId, data: data)
        done(DeliveryStatus.ok)
      } else {
        self.transfers.onRequest(peerId: peerId, data: data, done: done)
      }
      return true
    }
  }

  func createSink(_ transfer: FileTransfer) -> FileSink? {
    guard storable else { return nil }
    stored[transfer.id] = Data()
    return MemorySink(files: self, transfer: transfer)
  }

  func onTransferChanged(_ transfer: FileTransfer) {
    changes.append(Change(state: transfer.state, bytes: transfer.bytes))
  }

  func releaseWrites() {
    holdWrites = false
    let writes = heldWrites
    heldWrites = []
    writes.forEach { $0() }
  }
}

/// `/file` transfers between two engines, ported from Android's FileTransfersTest.
final class FileTransfersTests: XCTestCase {
  private var scheduler: FakeScheduler!
  private var network: Network!
  private var a: Phone!
  private var b: Phone!
  private var filesA: Files!
  private var filesB: Files!
  private let content = Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
  private var source: MemorySource!
  /// More than the chunks one window holds.
  private let big = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 * 13) })

  override func setUp() {
    scheduler = FakeScheduler()
    network = Network(scheduler: scheduler)
    network.maxFrameSize = 509
    a = network.phone("A", "AA:AA", PeerId(Data(repeating: 0x11, count: 16)))
    b = network.phone("B", "BB:BB", PeerId(Data(repeating: 0x77, count: 16)))
    filesA = Files(a, scheduler)
    filesB = Files(b, scheduler)
    source = MemorySource(content)
  }

  private func settle(_ ms: Int64 = 2_000) {
    scheduler.advance(ms)
  }

  @discardableResult
  private func pair() -> Network.Connection {
    let connection = network.connect(a, b, userInitiated: true)
    settle()
    XCTAssertTrue(a.engine.isConnected(deviceId: b.address))
    return connection
  }

  /// A offers `data` to B; returns both ends once B has the offer.
  private func offer(_ data: Data? = nil, from: MemorySource? = nil) -> (FileTransfer, FileTransfer) {
    let data = data ?? content
    let sent = filesA.transfers.offer(
      peerId: b.peerId, name: "사진.jpg", size: Int64(data.count), mime: "image/jpeg", source: from ?? source)
    settle()
    return (sent, filesB.transfers.all().last!)
  }

  func testAFileGoesThroughOnceTheReceiversUserAccepts() {
    pair()
    let (sent, offered) = offer()
    XCTAssertEqual(sent.state, .waiting)
    XCTAssertEqual(offered.state, .offered)
    XCTAssertEqual(offered.name, "사진.jpg")
    XCTAssertEqual(offered.size, 40_000)
    XCTAssertEqual(offered.mime, "image/jpeg")
    XCTAssertEqual(offered.transferId, sent.transferId)

    XCTAssertTrue(filesB.transfers.respond(id: offered.id, accept: true))
    settle()

    XCTAssertEqual(offered.state, .completed)
    XCTAssertEqual(offered.path, "/received/사진.jpg")
    XCTAssertEqual(filesB.stored[offered.id], content)
    XCTAssertEqual(sent.state, .completed)
    XCTAssertTrue(source.closed)
    // Progress, chunk by chunk, on both phones.
    let progress = [
      Files.Change(state: .transferring, bytes: 0),
      Files.Change(state: .transferring, bytes: 16_384),
      Files.Change(state: .transferring, bytes: 32_768),
      Files.Change(state: .completed, bytes: 40_000),
    ]
    XCTAssertEqual(filesA.changes, [Files.Change(state: .waiting, bytes: 0)] + progress)
    XCTAssertEqual(filesB.changes, [Files.Change(state: .offered, bytes: 0)] + progress)
    // A received file stays until it's dismissed; a sent one doesn't.
    XCTAssertTrue(filesA.transfers.all().isEmpty)
    XCTAssertEqual(filesB.transfers.all().map(\.id), [offered.id])
    XCTAssertTrue(filesB.transfers.dismiss(id: offered.id))
    XCTAssertTrue(filesB.transfers.all().isEmpty)
  }

  func testDecliningEndsTheTransferOnBothPhones() {
    pair()
    let (sent, offered) = offer()

    XCTAssertTrue(filesB.transfers.respond(id: offered.id, accept: false))
    settle()

    XCTAssertEqual(offered.state, .declined)
    XCTAssertFalse(offered.byPeer)
    XCTAssertEqual(sent.state, .declined)
    XCTAssertTrue(sent.byPeer)
    XCTAssertTrue(source.closed)
    XCTAssertTrue(filesA.transfers.all().isEmpty)
    XCTAssertTrue(filesB.transfers.all().isEmpty)
  }

  func testTheReceiversUserHasTwoMinutesToAnswer() {
    pair()
    let (sent, offered) = offer()

    scheduler.advance(FileTransfers.answerTimeoutMs)
    settle()

    XCTAssertEqual(offered.state, .failed)
    XCTAssertEqual(offered.reason, TransferFailure.timeout)
    XCTAssertEqual(sent.state, .failed)
    XCTAssertEqual(sent.reason, TransferFailure.timeout)
  }

  func testTheSenderStopsWaitingForAnAnswerThatCantCome() {
    let connection = pair()
    let (sent, _) = offer()
    connection.drop()

    scheduler.advance(FileTransfers.senderAnswerTimeoutMs)

    XCTAssertEqual(sent.state, .failed)
    XCTAssertEqual(sent.reason, TransferFailure.timeout)
  }

  func testTheSenderCanCancelWhileTheFileIsOnItsWay() {
    pair()
    filesB.holdWrites = true
    let (sent, offered) = offer()
    filesB.transfers.respond(id: offered.id, accept: true)
    settle()
    XCTAssertEqual(offered.state, .transferring)

    XCTAssertTrue(filesA.transfers.cancel(id: sent.id))
    settle()

    XCTAssertEqual(sent.state, .canceled)
    XCTAssertFalse(sent.byPeer)
    XCTAssertEqual(offered.state, .canceled)
    XCTAssertTrue(offered.byPeer)
    XCTAssertEqual(filesB.aborted, [offered.id])
    // Writes that end afterwards change nothing.
    filesB.releaseWrites()
    settle()
    XCTAssertEqual(offered.state, .canceled)
    XCTAssertFalse(filesA.transfers.cancel(id: sent.id))
  }

  func testTheReceiverCanCancelWhileTheFileIsOnItsWay() {
    pair()
    filesB.holdWrites = true
    let (sent, offered) = offer()
    filesB.transfers.respond(id: offered.id, accept: true)
    settle()

    XCTAssertTrue(filesB.transfers.cancel(id: offered.id))
    settle()

    XCTAssertEqual(offered.state, .canceled)
    XCTAssertFalse(offered.byPeer)
    XCTAssertEqual(sent.state, .canceled)
    XCTAssertTrue(sent.byPeer)
    XCTAssertTrue(source.closed)
  }

  func testAPeerWithoutFileTransferIsToldApart() {
    b.caps = Capabilities(builtins: [], apps: [testApp])
    pair()

    let sent = filesA.transfers.offer(peerId: b.peerId, name: "a.txt", size: 1, mime: "text/plain", source: MemorySource(Data([1])))
    settle()

    XCTAssertEqual(sent.state, .failed)
    XCTAssertEqual(sent.reason, TransferFailure.unsupported)
    XCTAssertEqual(sent.status, DeliveryStatus.noReceiver)
    XCTAssertTrue(filesB.transfers.all().isEmpty)
  }

  func testAnEmptyFileIsDoneOnceItsAccepted() {
    pair()
    let (sent, offered) = offer(Data(), from: MemorySource(Data()))

    filesB.transfers.respond(id: offered.id, accept: true)
    settle()

    XCTAssertEqual(offered.state, .completed)
    XCTAssertEqual(filesB.stored[offered.id], Data())
    XCTAssertEqual(sent.state, .completed)
  }

  func testAFileThatCantBeStoredFailsOnBothPhones() {
    pair()
    filesB.storable = false
    let (sent, offered) = offer()

    filesB.transfers.respond(id: offered.id, accept: true)
    settle()

    XCTAssertEqual(offered.state, .failed)
    XCTAssertEqual(offered.reason, TransferFailure.storage)
    XCTAssertEqual(sent.state, .failed)
    XCTAssertEqual(sent.reason, TransferFailure.peer)
  }

  func testAFileThatCantBeReadIsCanceledOnTheReceiver() {
    pair()
    source.failAt = FileMessage.chunkSize
    let (sent, offered) = offer()

    filesB.transfers.respond(id: offered.id, accept: true)
    settle()

    XCTAssertEqual(sent.state, .failed)
    XCTAssertEqual(sent.reason, TransferFailure.read)
    XCTAssertEqual(offered.state, .canceled)
    XCTAssertEqual(filesB.aborted, [offered.id])
  }

  func testTheReceiverGivesUpWhenTheChunksStopComing() {
    let connection = pair()
    filesB.holdWrites = true
    let (sent, offered) = offer(big, from: MemorySource(big))
    filesB.transfers.respond(id: offered.id, accept: true)
    settle()
    connection.drop()
    filesB.releaseWrites()

    scheduler.advance(FileTransfers.idleTimeoutMs)

    // The chunks in flight were sent, but their ACKs never came.
    XCTAssertEqual(sent.state, .failed)
    XCTAssertEqual(sent.reason, TransferFailure.linkLost)
    XCTAssertEqual(offered.state, .failed)
    XCTAssertEqual(offered.reason, TransferFailure.timeout)
    XCTAssertEqual(filesB.aborted, [offered.id])
  }

  func testATransferCarriesOnAfterAShortLinkLoss() {
    let connection = pair()
    filesB.holdWrites = true
    let (sent, offered) = offer(big, from: MemorySource(big))
    filesB.transfers.respond(id: offered.id, accept: true)
    settle()
    // The first chunks are written, but their ACKs are lost with the link.
    connection.drop()
    filesB.releaseWrites()
    settle(5_000)

    network.connect(a, b)
    settle()

    XCTAssertEqual(sent.state, .completed)
    XCTAssertEqual(offered.state, .completed)
    XCTAssertEqual(filesB.stored[offered.id], big)
  }

  func testAPeerCantFloodThisPhoneWithOffers() {
    pair()
    let sent = (0...FileTransfers.maxIncomingPerPeer).map {
      filesA.transfers.offer(peerId: b.peerId, name: "\($0).txt", size: 1, mime: "text/plain", source: MemorySource(Data([1])))
    }
    settle()

    XCTAssertEqual(filesB.transfers.all().count, FileTransfers.maxIncomingPerPeer)
    XCTAssertEqual(sent.last?.state, .failed)
    XCTAssertEqual(sent.last?.reason, TransferFailure.busy)
  }

  func testChunksThatDontBelongToAnAcceptedTransferAreRefused() {
    pair()
    let (_, offered) = offer()
    var statuses: [Int] = []
    func request(_ payload: Data) {
      filesB.transfers.onRequest(
        peerId: a.peerId,
        data: DataEnvelope(msgId: 900, flags: Envelope.flagAckReq, path: FileMessage.path, replyTo: 0, payload: payload)
      ) { statuses.append($0) }
    }

    request(FileMessage.chunk(transferId: offered.transferId, offset: 0, data: Data([1])))
    request(FileMessage.chunk(transferId: 12345, offset: 0, data: Data([1])))
    request(Data([9]))
    request(Data())

    XCTAssertEqual(
      statuses, [DeliveryStatus.denied, DeliveryStatus.denied, DeliveryStatus.unsupported, DeliveryStatus.malformed])
    XCTAssertEqual(offered.state, .offered)
  }

  func testAChunkOutOfOrderFailsTheTransfer() {
    pair()
    let (sent, offered) = offer()
    filesB.transfers.respond(id: offered.id, accept: true)
    var statuses: [Int] = []

    filesB.transfers.onRequest(
      peerId: a.peerId,
      data: DataEnvelope(
        msgId: 900, flags: Envelope.flagAckReq, path: FileMessage.path, replyTo: 0,
        payload: FileMessage.chunk(transferId: sent.transferId, offset: 100, data: Data([1])))
    ) { statuses.append($0) }
    settle()

    XCTAssertEqual(statuses, [DeliveryStatus.malformed])
    XCTAssertEqual(offered.state, .failed)
    XCTAssertEqual(sent.state, .failed)
    XCTAssertEqual(sent.reason, TransferFailure.peer)
  }

  func testRemovingThePeerEndsItsTransfers() {
    pair()
    let (sent, offered) = offer()

    filesA.transfers.peerRemoved(b.peerId)
    filesB.transfers.peerRemoved(a.peerId)

    XCTAssertEqual(sent.state, .failed)
    XCTAssertEqual(sent.reason, TransferFailure.unpaired)
    XCTAssertEqual(offered.state, .failed)
    XCTAssertTrue(filesB.transfers.all().isEmpty)
  }
}
