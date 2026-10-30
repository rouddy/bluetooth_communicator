import Foundation

@testable import Runner

// The Swift copy of android/.../protocol/EngineHarness.kt: engines connected in memory
// on a virtual clock.

let testApp = AppIdentity(packageName: "com.example.test", certHash: String(repeating: "ab", count: 32))

final class FakeScheduler: EngineScheduler {
  private final class Task: Cancellable {
    let at: Int64
    let seq: Int
    let action: () -> Void
    var cancelled = false

    init(at: Int64, seq: Int, action: @escaping () -> Void) {
      self.at = at
      self.seq = seq
      self.action = action
    }

    func cancel() {
      cancelled = true
    }
  }

  private var time: Int64 = 0
  private var seq = 0
  private var tasks: [Task] = []

  func now() -> Int64 { time }

  func schedule(_ delayMs: Int64, _ action: @escaping () -> Void) -> Cancellable {
    let task = Task(at: time + delayMs, seq: seq, action: action)
    seq += 1
    tasks.append(task)
    return task
  }

  func advance(_ ms: Int64) {
    let end = time + ms
    while true {
      tasks.removeAll { $0.cancelled }
      guard let next = tasks.min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }), next.at <= end else { break }
      tasks.removeAll { $0 === next }
      time = next.at
      next.action()
    }
    time = end
  }
}

final class InMemoryPeerStore: PeerStore {
  let localPeerId: PeerId
  private var msgId: UInt32 = 0
  var peerMap: [PeerId: StoredPeer] = [:]
  var order: [PeerId] = []
  var keys: [PeerId: Data] = [:]

  init(localPeerId: PeerId) {
    self.localPeerId = localPeerId
  }

  func nextMsgId() -> UInt32 {
    msgId += 1
    return msgId
  }

  func peers() -> [StoredPeer] { order.compactMap { peerMap[$0] } }

  func key(_ peerId: PeerId) -> PeerKey? { keys[peerId].map { RawPeerKey(key: $0) } }

  func savePaired(_ peer: StoredPeer, key: Data) {
    peers().filter { $0.deviceId == peer.deviceId && $0.peerId != peer.peerId }.forEach { remove($0.peerId) }
    update(peer)
    keys[peer.peerId] = key
  }

  func update(_ peer: StoredPeer) {
    if peerMap[peer.peerId] == nil {
      order.append(peer.peerId)
    }
    peerMap[peer.peerId] = peer
  }

  func deleteKey(_ peerId: PeerId) {
    keys.removeValue(forKey: peerId)
  }

  func remove(_ peerId: PeerId) {
    peerMap.removeValue(forKey: peerId)
    order.removeAll { $0 == peerId }
    keys.removeValue(forKey: peerId)
  }
}

/// One phone: an engine plus a host that records what it's told.
final class Phone: EngineHost {
  let name: String
  let address: String
  let store: InMemoryPeerStore
  private let scheduler: FakeScheduler
  private unowned let network: Network
  private(set) var engine: ProtocolEngine!
  var events: [EngineEvent] = []
  var delivered: [DataEnvelope] = []

  /// Answers pairing prompts after `approvalDelayMs`; nil leaves them unanswered.
  var approve: Bool? = true
  var approvalDelayMs: Int64 = 0
  var caps = Capabilities(builtins: ["/control/media"], apps: [testApp])
  /// Status for each delivery; nil holds the delivery open in `heldDeliveries`.
  var deliverStatus: Int? = DeliveryStatus.ok
  var heldDeliveries: [(Int) -> Void] = []

  var peerId: PeerId { store.localPeerId }

  init(name: String, address: String, peerId: PeerId, scheduler: FakeScheduler, network: Network) {
    self.name = name
    self.address = address
    self.store = InMemoryPeerStore(localPeerId: peerId)
    self.scheduler = scheduler
    self.network = network
    engine = ProtocolEngine(host: self, store: store, scheduler: scheduler)
  }

  func writeFrame(linkId: Int, frame: Data) { network.write(from: self, linkId: linkId, frame: frame) }

  func closeLink(linkId: Int) { network.close(from: self, linkId: linkId) }

  func localIdentity() -> LocalIdentity { LocalIdentity(name: name, platform: Platform.ios, appVersion: "test") }

  func canPrompt() -> Bool { true }

  func localCaps() -> Capabilities { caps }

  func deliver(peerId: PeerId, data: DataEnvelope, done: @escaping (Int) -> Void) {
    delivered.append(data)
    if let status = deliverStatus {
      done(status)
    } else {
      heldDeliveries.append(done)
    }
  }

  func onEvent(_ event: EngineEvent) {
    events.append(event)
    if case .pairingRequest(let deviceId, _, _, _, _) = event, let answer = approve {
      _ = scheduler.schedule(approvalDelayMs) { [unowned self] in
        self.engine.respondPairing(deviceId: deviceId, accept: answer)
      }
    }
  }

  func log(_ message: String) {}

  var pairingRequests: [EngineEvent] {
    events.filter { if case .pairingRequest = $0 { return true } else { return false } }
  }

  var pairingResults: [String] {
    events.compactMap { if case .pairingResult(_, _, let result) = $0 { return result } else { return nil } }
  }

  func send(to: Phone, _ payload: Data, path: String = "\(testApp.packageName)/chat", ttlMs: Int64 = 0) -> Box<[Int]> {
    let results = Box<[Int]>([])
    engine.send(peerId: to.peerId, path: path, payload: payload, replyTo: 0, ttlMs: ttlMs, app: testApp) {
      results.value.append($0)
    }
    return results
  }
}

final class Box<T> {
  var value: T

  init(_ value: T) {
    self.value = value
  }
}

/// Connects engines in memory. Each frame takes 1 ms; a write completes when the frame
/// arrives. Closing a link (the central's job) also takes it down on the other side.
final class Network {
  final class Connection {
    let central: Phone
    let centralLink: Int
    let peripheral: Phone
    let peripheralLink: Int
    var open = true
    /// False when the far end's app died but Bluetooth stayed connected.
    var delivers = true

    init(central: Phone, centralLink: Int, peripheral: Phone, peripheralLink: Int) {
      self.central = central
      self.centralLink = centralLink
      self.peripheral = peripheral
      self.peripheralLink = peripheralLink
    }

    func drop() {
      guard open else { return }
      open = false
      central.engine.linkDown(linkId: centralLink)
      peripheral.engine.linkDown(linkId: peripheralLink)
    }
  }

  private let scheduler: FakeScheduler
  var connections: [Connection] = []
  private var nextLinkId = 1
  var maxFrameSize = 20
  /// Frames for which this returns true vanish (their write still succeeds).
  var lose: (Phone, Data) -> Bool = { _, _ in false }

  init(scheduler: FakeScheduler) {
    self.scheduler = scheduler
  }

  func phone(_ name: String, _ address: String, _ peerId: PeerId) -> Phone {
    Phone(name: name, address: address, peerId: peerId, scheduler: scheduler, network: self)
  }

  @discardableResult
  func connect(_ central: Phone, _ peripheral: Phone, userInitiated: Bool = false) -> Connection {
    let connection = Connection(central: central, centralLink: nextLinkId, peripheral: peripheral, peripheralLink: nextLinkId + 1)
    nextLinkId += 2
    connections.append(connection)
    peripheral.engine.linkUp(
      linkId: connection.peripheralLink, role: .peripheral, deviceId: central.address, maxFrameSize: maxFrameSize, userInitiated: false)
    central.engine.linkUp(
      linkId: connection.centralLink, role: .central, deviceId: peripheral.address, maxFrameSize: maxFrameSize,
      userInitiated: userInitiated)
    return connection
  }

  private func find(_ phone: Phone, _ linkId: Int) -> Connection {
    connections.first {
      ($0.central === phone && $0.centralLink == linkId) || ($0.peripheral === phone && $0.peripheralLink == linkId)
    }!
  }

  func write(from: Phone, linkId: Int, frame: Data) {
    let connection = find(from, linkId)
    _ = scheduler.schedule(1) { [unowned self] in
      // Like GATT: an attribute value over 512 bytes is rejected.
      if !connection.open || frame.count > Frames.maxFrameSize {
        from.engine.frameWritten(linkId: linkId, success: false)
        return
      }
      from.engine.frameWritten(linkId: linkId, success: true)
      if !connection.delivers || self.lose(from, frame) {
        return
      }
      if from === connection.central {
        connection.peripheral.engine.frameReceived(linkId: connection.peripheralLink, frame: frame)
      } else {
        connection.central.engine.frameReceived(linkId: connection.centralLink, frame: frame)
      }
    }
  }

  func close(from: Phone, linkId: Int) {
    let connection = find(from, linkId)
    guard connection.open else { return }
    connection.open = false
    _ = scheduler.schedule(1) {
      if from === connection.central {
        connection.peripheral.engine.linkDown(linkId: connection.peripheralLink)
      } else {
        connection.central.engine.linkDown(linkId: connection.centralLink)
      }
    }
  }
}
