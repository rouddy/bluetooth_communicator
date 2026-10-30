import Foundation

// The Swift port of android/.../protocol/Engine.kt. Keep the two in step: the same
// structure, names, and behavior, checked by the same test cases.

enum Role: String {
  case central = "CENTRAL"
  case peripheral = "PERIPHERAL"
}

protocol Cancellable {
  func cancel()
}

/// Time and timers; tests drive them with a virtual clock.
protocol EngineScheduler {
  /// Monotonic milliseconds.
  func now() -> Int64

  func schedule(_ delayMs: Int64, _ action: @escaping () -> Void) -> Cancellable
}

enum PeerState: String {
  /// Has K; reconnected automatically.
  case paired = "PAIRED"
  /// Has K, but the peer answered UNKNOWN_PEER (it deleted us or reinstalled).
  case repairNeeded = "REPAIR_NEEDED"
  /// Has K, but an AUTH didn't verify; possibly an attack, so no automatic reconnects.
  case badMac = "BAD_MAC"
  /// The peer sent UNPAIR; K is gone.
  case unpairedByPeer = "UNPAIRED_BY_PEER"
}

struct StoredPeer: Equatable {
  var peerId: PeerId
  var name: String
  var deviceId: String
  var platform: Int
  var state: PeerState
}

/// Peers that went through app pairing, and their keys (6.6).
protocol PeerStore: AnyObject {
  var localPeerId: PeerId { get }

  /// The next msgId (9절): increases across all peers and restarts, never 0.
  func nextMsgId() -> UInt32

  func peers() -> [StoredPeer]

  func key(_ peerId: PeerId) -> PeerKey?

  /// Stores K and the peer, replacing entries with the same peerId or deviceId.
  func savePaired(_ peer: StoredPeer, key: Data)

  func update(_ peer: StoredPeer)

  func deleteKey(_ peerId: PeerId)

  /// Forgets the peer and its key.
  func remove(_ peerId: PeerId)
}

struct LocalIdentity {
  var name: String
  var platform: Int
  var appVersion: String
}

/// What this phone can receive, sent to peers as CAPS (7절).
struct Capabilities: Equatable {
  var builtins: [String]
  var apps: [AppIdentity]
}

enum EngineEvent: Equatable {
  /// A session was established (6.1); `connected` on the platform channel.
  case connected(deviceId: String, peerId: PeerId, name: String)
  /// No established link to `deviceId` is left.
  case disconnected(deviceId: String)
  /// Both sides show `code` and wait for the user (6.3).
  case pairingRequest(deviceId: String, peerId: PeerId, name: String, code: String, repair: Bool)
  /// The end of an app pairing: `paired`, or why it failed.
  case pairingResult(deviceId: String, peerId: PeerId, result: String)
  /// A REJECT was sent (`byPeer` false) or received.
  case peerRejected(deviceId: String, reason: Int, byPeer: Bool)
  /// The peer removed this phone (UNPAIR).
  case peerUnpaired(deviceId: String, peerId: PeerId)
  /// The stored peers, their connection state, or their CAPS changed.
  case peersChanged
  case error(message: String)
}

protocol EngineHost: AnyObject {
  /// Writes one frame; answer with `ProtocolEngine.frameWritten`.
  func writeFrame(linkId: Int, frame: Data)

  /// Drops the link. The engine has already forgotten it.
  func closeLink(linkId: Int)

  func localIdentity() -> LocalIdentity

  /// Whether the user can be asked to approve a pairing right now.
  func canPrompt() -> Bool

  func localCaps() -> Capabilities

  /// Hands a received DATA to its target; `done` gets the ACK status.
  func deliver(peerId: PeerId, data: DataEnvelope, done: @escaping (Int) -> Void)

  func onEvent(_ event: EngineEvent)

  func log(_ message: String)
}

struct PeerSummary {
  var peer: StoredPeer
  var connected: Bool
  var caps: Capabilities?
}

/// The derivations of 6.3 and 6.4.
enum Derivation {
  private static let commitLabel = Data("rbc-commit-v1".utf8)
  private static let pairKeyLabel = Data("rbc-pair-key-v1".utf8)
  private static let codeLabel = Data("rbc-code-v1".utf8)
  private static let confirmLabel = Data("rbc-confirm-v1".utf8)
  private static let authLabel = Data("rbc-auth-v1".utf8)
  private static let sessionLabel = Data("rbc-session-v1".utf8)

  static func tHello(helloC: Data, helloP: Data) -> Data { Crypto.sha256(helloC, helloP) }

  static func commit(publicKeyP: Data) -> Data { Crypto.sha256(commitLabel, publicKeyP) }

  static func tPair(tHello: Data, publicKeyP: Data, publicKeyC: Data) -> Data {
    Crypto.sha256(tHello, publicKeyP, publicKeyC)
  }

  static func pairKey(sharedSecret: Data, tPair: Data) -> Data {
    Crypto.hkdf(ikm: sharedSecret, salt: tPair, info: pairKeyLabel, length: Crypto.keySize)
  }

  /// Six digits from the first four bytes (u32 LE) of H("rbc-code-v1" ‖ T_pair).
  static func code(tPair: Data) -> String {
    var reader = ByteReader(Crypto.sha256(codeLabel, tPair))
    let value = (try? reader.u32()) ?? 0
    return String(format: "%06d", value % 1_000_000)
  }

  static func confirmMac(_ key: PeerKey, sender: PeerId, tPair: Data) -> Data {
    key.hmac(confirmLabel + sender.bytes + tPair)
  }

  static func authMac(_ key: PeerKey, sender: PeerId, tHello: Data) -> Data {
    key.hmac(authLabel + sender.bytes + tHello)
  }

  /// k(from→to), used for the SEALED records `from` sends.
  static func sessionKey(_ key: PeerKey, from: PeerId, to: PeerId, tHello: Data) -> Data {
    key.hmac(sessionLabel + from.bytes + to.bytes + tHello)
  }
}

/// The protocol of docs/protocol.md for every link of this phone: framing, the
/// handshake and app pairing, SEALED records, one link per peer, and delivery (ACK,
/// dedup, retransmission, TTL, flow control, CAPS, UNPAIR).
///
/// Not thread-safe: call it from one thread (the iOS host uses the main queue).
final class ProtocolEngine {
  static let priorityHandshake = 0
  static let priorityAck = 1
  static let priorityControl = 2
  static let priorityData = 3
  private static let priorityCount = 4

  static let handshakeTimeoutMs: Int64 = 10_000
  static let approvalTimeoutMs: Int64 = 60_000
  static let ackTimeoutMs: Int64 = 10_000
  static let unpairTimeoutMs: Int64 = 3_000
  static let dedupMs: Int64 = 120_000
  static let controlTtlMs: Int64 = 10_000
  static let defaultTtlMs: Int64 = 30_000
  static let maxTtlMs: Int64 = 60_000
  static let maxInFlight = 4
  static let maxDecryptFailures = 5
  static let retryDelayMs: Int64 = 1_000
  static let probeTimeoutMs: Int64 = 3_000

  /// A built-in path that only gets an ACK: proof that a link is alive.
  static let pingPath = "/ping"

  /// SEALED header and tag around an envelope.
  static let sealedOverhead = 6 + Record.gcmTagSize

  static let resultPaired = "paired"
  static let resultLinkLost = "linkLost"

  static func pairingFailure(_ reason: Int) -> String {
    switch reason {
    case RejectReason.userRejected: return "rejected"
    case RejectReason.timeout: return "timeout"
    case RejectReason.cannotPrompt: return "cannotPrompt"
    case RejectReason.commitMismatch: return "mismatch"
    case RejectReason.badMac: return "badMac"
    default: return RejectReason.name(reason)
    }
  }

  fileprivate enum Phase: String {
    case awaitHello = "AWAIT_HELLO"
    case awaitAuth = "AWAIT_AUTH"
    case pairing = "PAIRING"
    case established = "ESTABLISHED"
    case done = "DONE"
  }

  fileprivate final class Pairing {
    let repair: Bool
    var keyPair: Crypto.EcKeyPair?
    var commit: Data?
    var key: Data?
    var tPair: Data?
    var code: String?
    var localApproved = false
    var peerConfirmed = false
    var approvalTimer: Cancellable?

    init(repair: Bool) {
      self.repair = repair
    }
  }

  fileprivate final class Session {
    let sendKey: Data
    let receiveKey: Data
    var sendCounter: UInt64 = 0
    var window = ReplayWindow()
    var decryptFailures = 0

    init(sendKey: Data, receiveKey: Data) {
      self.sendKey = sendKey
      self.receiveKey = receiveKey
    }
  }

  fileprivate final class OutgoingRecord {
    let bytes: Data
    let priority: Int
    let onWritten: ((Bool) -> Void)?
    var frames: [Data]?
    var next = 0
    var tid = -1

    init(bytes: Data, priority: Int, onWritten: ((Bool) -> Void)?) {
      self.bytes = bytes
      self.priority = priority
      self.onWritten = onWritten
    }
  }

  fileprivate final class Link {
    let id: Int
    let role: Role
    let deviceId: String
    let userInitiated: Bool
    var maxFrameSize: Int
    unowned let host: EngineHost

    let reassembler = FrameReassembler(maxRecordSize: maxMessageBytes)
    var phase = Phase.awaitHello
    var ownHello: Data?
    var peerHello: Hello?
    var tHello: Data?
    var pairing: Pairing?
    var session: Session?
    var handshakeTimer: Cancellable?
    var closed = false

    /// HELLOs received; a deferred decision about an older HELLO is dropped.
    var helloCount = 0

    /// `/ping` msgIds waiting for their ACK.
    var probes: [UInt32: () -> Void] = [:]

    var peerId: PeerId? { peerHello?.peerId }
    var peerName: String { peerHello?.name ?? "" }
    var isLive: Bool { !closed && phase != .done }

    // Frame scheduling (4절, 9절): one queue per priority. The head record of the
    // highest non-empty priority sends its next frame, so handshakes, ACKs, and
    // commands slip in between the frames of a long record.
    private var queues = [[OutgoingRecord]](repeating: [], count: ProtocolEngine.priorityCount)
    private var tidsInUse = [Bool](repeating: false, count: Frames.tidCount)
    private var nextTid = 0
    private var writing: OutgoingRecord?
    private var pumping = false
    private var pumpAgain = false

    init(id: Int, role: Role, deviceId: String, userInitiated: Bool, maxFrameSize: Int, host: EngineHost) {
      self.id = id
      self.role = role
      self.deviceId = deviceId
      self.userInitiated = userInitiated
      self.maxFrameSize = maxFrameSize
      self.host = host
    }

    func enqueue(_ record: OutgoingRecord) {
      queues[record.priority].append(record)
      pump()
    }

    func frameWritten(_ success: Bool) {
      guard let record = writing else { return }
      writing = nil
      if !success {
        remove(record)
        record.onWritten?(false)
      } else {
        record.next += 1
        if record.next == record.frames!.count {
          remove(record)
          record.onWritten?(true)
        }
      }
      pump()
    }

    func failAll() {
      let records = queues.flatMap { $0 }
      queues = [[OutgoingRecord]](repeating: [], count: ProtocolEngine.priorityCount)
      writing = nil
      tidsInUse = [Bool](repeating: false, count: Frames.tidCount)
      records.forEach { $0.onWritten?(false) }
    }

    private func remove(_ record: OutgoingRecord) {
      queues[record.priority].removeAll { $0 === record }
      if record.tid >= 0 {
        tidsInUse[record.tid] = false
      }
    }

    private func pump() {
      // A host that completes a write synchronously calls frameWritten from inside
      // writeFrame; loop instead of recursing.
      if pumping {
        pumpAgain = true
        return
      }
      pumping = true
      defer { pumping = false }
      repeat {
        pumpAgain = false
        startNextFrame()
      } while pumpAgain
    }

    private func startNextFrame() {
      guard writing == nil, !closed,
        let record = queues.first(where: { !$0.isEmpty })?.first
      else { return }
      if record.frames == nil {
        record.tid = allocateTid()
        record.frames = Frames.split(record.bytes, tid: record.tid, maxFrameSize: maxFrameSize)
      }
      writing = record
      host.writeFrame(linkId: id, frame: record.frames![record.next])
    }

    private func allocateTid() -> Int {
      for step in 0..<Frames.tidCount {
        let tid = (nextTid + step) % Frames.tidCount
        if !tidsInUse[tid] {
          tidsInUse[tid] = true
          nextTid = (tid + 1) % Frames.tidCount
          return tid
        }
      }
      fatalError("No free tid")  // At most one record per priority is in progress.
    }
  }

  fileprivate final class Received {
    var status: Int?
    let at: Int64

    init(at: Int64) {
      self.at = at
    }
  }

  fileprivate final class Outgoing {
    let msgId: UInt32
    let envelope: Envelope
    let priority: Int
    let app: AppIdentity?
    let callback: (Int) -> Void
    var written = false
    var done = false
    var ttlTimer: Cancellable?
    var ackTimer: Cancellable?

    init(msgId: UInt32, envelope: Envelope, priority: Int, app: AppIdentity?, callback: @escaping (Int) -> Void) {
      self.msgId = msgId
      self.envelope = envelope
      self.priority = priority
      self.app = app
      self.callback = callback
    }
  }

  /// Delivery state per peer; outlives links so sends can wait for a reconnect.
  fileprivate final class PeerChannel {
    let peerId: PeerId
    var link: Link?
    var caps: Capabilities?
    var capsMsgId: Int64 = -1
    var maxMessageSize = Int64(maxMessageBytes)
    var outbox: [Outgoing] = []
    /// In sending order.
    var inFlight: [Outgoing] = []
    var received: [UInt32: Received] = [:]
    var retryScheduled = false

    init(peerId: PeerId) {
      self.peerId = peerId
    }

    func removeInFlight(_ msgId: UInt32) -> Outgoing? {
      guard let index = inFlight.firstIndex(where: { $0.msgId == msgId }) else { return nil }
      return inFlight.remove(at: index)
    }
  }

  private unowned let host: EngineHost
  private let store: PeerStore
  private let scheduler: EngineScheduler
  private var links: [Int: Link] = [:]
  private var channels: [PeerId: PeerChannel] = [:]

  init(host: EngineHost, store: PeerStore, scheduler: EngineScheduler) {
    self.host = host
    self.store = store
    self.scheduler = scheduler
  }

  // MARK: - Links

  /// A link became usable: for a central, its CCCD subscription succeeded; for a
  /// peripheral, the central subscribed. `maxFrameSize` is ATT MTU - 3 (capped at
  /// `Frames.maxFrameSize`).
  func linkUp(linkId: Int, role: Role, deviceId: String, maxFrameSize: Int, userInitiated: Bool) {
    if let old = links.removeValue(forKey: linkId) {
      teardown(old)
    }
    let link = Link(
      id: linkId, role: role, deviceId: deviceId, userInitiated: userInitiated,
      maxFrameSize: min(max(maxFrameSize, Frames.minFrameSize), Frames.maxFrameSize), host: host)
    links[linkId] = link
    host.log("Link \(linkId) up: \(role.rawValue) to \(deviceId), frames of \(link.maxFrameSize) bytes, user=\(userInitiated)")
    if role == .central {
      sendHello(link)
    } else {
      armHandshakeTimer(link)
    }
  }

  func hasLink(_ linkId: Int) -> Bool { links[linkId] != nil }

  /// The ATT MTU changed; frames split from now on use the new size.
  func setMaxFrameSize(linkId: Int, maxFrameSize: Int) {
    links[linkId]?.maxFrameSize = min(max(maxFrameSize, Frames.minFrameSize), Frames.maxFrameSize)
  }

  func frameReceived(linkId: Int, frame: Data) {
    guard let link = links[linkId], let record = link.reassembler.accept(frame) else { return }
    onRecord(link, record)
  }

  func frameWritten(linkId: Int, success: Bool) {
    links[linkId]?.frameWritten(success)
  }

  /// The link went away (disconnect, unsubscribe, Bluetooth off).
  func linkDown(linkId: Int) {
    if let link = links.removeValue(forKey: linkId) {
      teardown(link)
    }
  }

  /// Whether the host should (re)connect to `deviceId` on its own: a paired peer that
  /// has no link left (9절: not while another link to it exists).
  func shouldReconnect(deviceId: String) -> Bool {
    guard let peer = store.peers().first(where: { $0.deviceId == deviceId && $0.state == .paired }) else {
      return false
    }
    return shouldReconnect(peerId: peer.peerId)
  }

  /// Like `shouldReconnect(deviceId:)`, by peer: a central on iOS reaches a peer under
  /// another identifier than the one it used to connect to us.
  func shouldReconnect(peerId: PeerId) -> Bool {
    guard let peer = store.peers().first(where: { $0.peerId == peerId }), peer.state == .paired else {
      return false
    }
    return !links.values.contains { $0.isLive && ($0.deviceId == peer.deviceId || $0.peerId == peerId) }
  }

  /// Whether some link to `deviceId` is up or handshaking (any role).
  func hasLiveLink(deviceId: String) -> Bool {
    links.values.contains { $0.isLive && $0.deviceId == deviceId }
  }

  func isConnected(deviceId: String) -> Bool {
    links.values.contains { $0.phase == .established && $0.deviceId == deviceId }
  }

  func connectedSessions() -> [EngineEvent] {
    links.values.filter { $0.phase == .established }.map {
      .connected(deviceId: $0.deviceId, peerId: $0.peerId!, name: $0.peerName)
    }
  }

  /// Pairings waiting for this user's answer, to show again when the UI attaches.
  func pendingApprovals() -> [EngineEvent] {
    links.values.compactMap { link in
      guard let pairing = link.pairing, let code = pairing.code, !pairing.localApproved else { return nil }
      return .pairingRequest(
        deviceId: link.deviceId, peerId: link.peerId!, name: link.peerName, code: code, repair: pairing.repair)
    }
  }

  func peerSummaries() -> [PeerSummary] {
    store.peers().map { peer in
      let channel = channels[peer.peerId]
      return PeerSummary(peer: peer, connected: channel?.link?.phase == .established, caps: channel?.caps)
    }
  }

  /// The last CAPS `peerId` sent (kept across its sessions), or nil if none yet.
  func capsOf(_ peerId: PeerId) -> Capabilities? { channels[peerId]?.caps }

  private func close(_ link: Link) {
    guard !link.closed else { return }
    links.removeValue(forKey: link.id)
    teardown(link)
    host.closeLink(linkId: link.id)
  }

  private func teardown(_ link: Link) {
    host.log("Link \(link.id) to \(link.deviceId) down (\(link.phase.rawValue))")
    link.closed = true
    link.handshakeTimer?.cancel()
    if let pairing = link.pairing {
      pairing.approvalTimer?.cancel()
      // The UI is showing (or may show) its approval prompt; dismiss it.
      if pairing.code != nil, let peerId = link.peerId {
        host.onEvent(.pairingResult(deviceId: link.deviceId, peerId: peerId, result: ProtocolEngine.resultLinkLost))
      }
    }
    link.pairing = nil
    // Requeue unacknowledged messages first, in order; the write failures that failAll
    // reports for them are then ignored.
    endSession(link)
    link.failAll()
    link.reassembler.reset()
    link.phase = .done
    emitDisconnectedIfUnlinked(link.deviceId)
  }

  private func emitDisconnectedIfUnlinked(_ deviceId: String) {
    if !links.values.contains(where: { $0.phase == .established && $0.deviceId == deviceId && !$0.closed }) {
      host.onEvent(.disconnected(deviceId: deviceId))
    }
  }

  private func sendRecord(_ link: Link, _ bytes: Data, _ priority: Int, _ onWritten: ((Bool) -> Void)? = nil) {
    if link.closed {
      onWritten?(false)
      return
    }
    link.enqueue(OutgoingRecord(bytes: bytes, priority: priority, onWritten: onWritten))
  }

  // MARK: - Handshake

  private func sendHello(_ link: Link) {
    link.phase = .awaitHello
    link.peerHello = nil
    link.tHello = nil
    link.pairing = nil
    let bytes = ownHello()
    link.ownHello = bytes
    sendRecord(link, bytes, ProtocolEngine.priorityHandshake)
    armHandshakeTimer(link)
  }

  private func ownHello() -> Data {
    let identity = host.localIdentity()
    var generator = SystemRandomNumberGenerator()
    let nonce = Data((0..<Record.nonceSize).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    return Record.encode(.hello(Hello(
      version: protocolVersion,
      peerId: store.localPeerId,
      nonce: nonce,
      name: identity.name,
      platform: identity.platform,
      appVersion: identity.appVersion,
      maxMessageSize: UInt32(maxMessageBytes))))
  }

  /// 6.5: a central closes a link whose handshake doesn't finish in time. A
  /// peripheral can't close it, but stops counting it as a link to that peer, or a
  /// central that silently gave up would block reconnects. A new HELLO_c revives it.
  private func armHandshakeTimer(_ link: Link) {
    link.handshakeTimer?.cancel()
    link.handshakeTimer = scheduler.schedule(ProtocolEngine.handshakeTimeoutMs) { [unowned self] in
      guard link.isLive, link.phase != .established else { return }
      switch link.role {
      case .central:
        self.host.onEvent(.error(message: "Handshake with \(link.deviceId) timed out"))
        self.close(link)
      case .peripheral:
        link.pairing = nil
        link.phase = .done
        self.emitDisconnectedIfUnlinked(link.deviceId)
      }
    }
  }

  private func onRecord(_ link: Link, _ bytes: Data) {
    guard !link.closed else { return }
    let record: Record
    do {
      record = try Record.decode(bytes)
    } catch {
      host.log("Dropped a malformed record from \(link.deviceId): \(error)")
      return
    }
    switch record {
    case .hello(let hello):
      onHello(link, hello, bytes)
    case .sealed(let counter, let body):
      onSealed(link, counter: counter, body: body)
    default:
      if link.phase != .established && link.phase != .done {
        onHandshakeRecord(link, record)
      }
    }
  }

  private func onHello(_ link: Link, _ hello: Hello, _ bytes: Data) {
    if hello.peerId == store.localPeerId {
      host.log("Ignored a HELLO with this phone's own peerId")
      return
    }
    link.helloCount += 1
    host.log("HELLO from \(link.deviceId) (\(hello.peerId), \(hello.name ?? "")) on link \(link.id) in \(link.phase.rawValue)")
    switch link.role {
    case .peripheral:
      // A new HELLO_c restarts the handshake, e.g. the peer app restarted (6.5).
      if link.phase != .awaitHello {
        resetPeripheral(link)
      }
      link.peerHello = hello
      if hello.version < protocolVersion {
        reject(link, RejectReason.unsupportedVersion)
        return
      }
      resolveOtherLink(link) { [unowned self] in
        let own = self.ownHello()
        link.ownHello = own
        link.tHello = Derivation.tHello(helloC: bytes, helloP: own)
        link.phase = .awaitAuth
        self.sendRecord(link, own, ProtocolEngine.priorityHandshake)
        self.armHandshakeTimer(link)
      }
    case .central:
      if link.phase == .done {
        return
      }
      if link.phase != .awaitHello {
        // A peripheral never sends HELLO unprompted; start over.
        endSession(link)
        sendHello(link)
        return
      }
      link.peerHello = hello
      link.tHello = Derivation.tHello(helloC: link.ownHello!, helloP: bytes)
      if hello.version < protocolVersion {
        reject(link, RejectReason.unsupportedVersion)
        return
      }
      resolveOtherLink(link) { [unowned self] in self.continueAsCentral(link) }
    }
  }

  private func resetPeripheral(_ link: Link) {
    if let pairing = link.pairing {
      pairing.approvalTimer?.cancel()
      if pairing.code != nil, let peerId = link.peerId {
        host.onEvent(.pairingResult(deviceId: link.deviceId, peerId: peerId, result: ProtocolEngine.resultLinkLost))
      }
    }
    link.pairing = nil
    let wasEstablished = link.phase == .established
    endSession(link)
    link.phase = .awaitHello
    if wasEstablished {
      emitDisconnectedIfUnlinked(link.deviceId)
    }
  }

  /// 6.1: AUTH if we have K, app pairing if the user asked for this link, else REJECT.
  private func continueAsCentral(_ link: Link) {
    let peerId = link.peerId!
    let stored = store.peers().first { $0.peerId == peerId }
    let key = store.key(peerId)
    host.log("Central on link \(link.id): key=\(key != nil), state=\(stored?.state.rawValue ?? "nil"), user=\(link.userInitiated)")
    if let key, stored?.state == .paired || !link.userInitiated {
      sendAuth(link, key)
    } else if link.userInitiated {
      link.pairing = Pairing(repair: key != nil)
      link.phase = .pairing
      sendRecord(link, Record.encode(.pairRequest), ProtocolEngine.priorityHandshake)
    } else {
      // Connected on our own to a phone we hold no key for: it reinstalled the app
      // (new peerId) under the address of a peer we know.
      store.peers()
        .filter { $0.deviceId == link.deviceId && $0.state == .paired }
        .forEach { markState($0.peerId, .repairNeeded) }
      reject(link, RejectReason.unknownPeer)
    }
  }

  private func sendAuth(_ link: Link, _ key: PeerKey) {
    link.phase = .awaitAuth
    let mac = Derivation.authMac(key, sender: store.localPeerId, tHello: link.tHello!)
    sendRecord(link, Record.encode(.auth(mac: mac)), ProtocolEngine.priorityHandshake)
  }

  private func onHandshakeRecord(_ link: Link, _ record: Record) {
    if case .reject(let reason) = record {
      onReject(link, reason)
      return
    }
    switch link.phase {
    case .awaitAuth:
      switch record {
      case .auth(let mac) where link.role == .central: onAuthAsCentral(link, mac)
      case .auth(let mac): onAuthAsPeripheral(link, mac)
      case .pairRequest where link.role == .peripheral: startPairingAsPeripheral(link)
      default: host.log("Unexpected \(record) from \(link.deviceId)")
      }
    case .pairing:
      onPairingRecord(link, record)
    default:
      host.log("Unexpected \(record) from \(link.deviceId)")
    }
  }

  private func onAuthAsCentral(_ link: Link, _ mac: Data) {
    let peerId = link.peerId!
    guard let key = store.key(peerId) else {
      reject(link, RejectReason.unknownPeer)
      return
    }
    guard Crypto.constantTimeEquals(Derivation.authMac(key, sender: peerId, tHello: link.tHello!), mac) else {
      markState(peerId, .badMac)
      reject(link, RejectReason.badMac)
      return
    }
    establish(link, key)
  }

  private func onAuthAsPeripheral(_ link: Link, _ mac: Data) {
    let peerId = link.peerId!
    guard let key = store.key(peerId) else {
      reject(link, RejectReason.unknownPeer)
      return
    }
    guard Crypto.constantTimeEquals(Derivation.authMac(key, sender: peerId, tHello: link.tHello!), mac) else {
      markState(peerId, .badMac)
      reject(link, RejectReason.badMac)
      return
    }
    let own = Derivation.authMac(key, sender: store.localPeerId, tHello: link.tHello!)
    sendRecord(link, Record.encode(.auth(mac: own)), ProtocolEngine.priorityHandshake)
    establish(link, key)
  }

  /// Sends REJECT and ends the handshake; a central then closes the link (6.1).
  private func reject(_ link: Link, _ reason: Int) {
    let central = link.role == .central
    sendRecord(link, Record.encode(.reject(reason: reason)), ProtocolEngine.priorityHandshake) { [unowned self] _ in
      if central {
        self.close(link)
      }
    }
    handshakeEnded(link, reason, byPeer: false)
  }

  private func onReject(_ link: Link, _ reason: Int) {
    handshakeEnded(link, reason, byPeer: true)
    if link.role == .central {
      close(link)
    }
  }

  private func handshakeEnded(_ link: Link, _ reason: Int, byPeer: Bool) {
    host.log("Handshake on link \(link.id) ended: \(RejectReason.name(reason))\(byPeer ? " from the peer" : "")")
    link.handshakeTimer?.cancel()
    let pairing = link.pairing
    link.pairing = nil
    pairing?.approvalTimer?.cancel()
    link.phase = .done
    if let peerId = link.peerId {
      if byPeer && reason == RejectReason.unknownPeer {
        // The peer has no key for us: it deleted us, or reinstalled. Keep K (the
        // REJECT isn't authenticated) but stop reconnecting (6.5).
        markState(peerId, .repairNeeded)
      }
      if reason == RejectReason.badMac && pairing == nil {
        // Either side of a failed AUTH: possibly an attack, so no automatic
        // reconnects and no automatic re-pairing (6.5).
        markState(peerId, .badMac)
      }
      if pairing != nil {
        host.onEvent(.pairingResult(
          deviceId: link.deviceId, peerId: peerId, result: ProtocolEngine.pairingFailure(reason)))
      }
    }
    if reason != RejectReason.alreadyConnected {
      host.onEvent(.peerRejected(deviceId: link.deviceId, reason: reason, byPeer: byPeer))
    }
    emitDisconnectedIfUnlinked(link.deviceId)
  }

  private func markState(_ peerId: PeerId, _ state: PeerState) {
    guard var stored = store.peers().first(where: { $0.peerId == peerId }), stored.state != state else { return }
    stored.state = state
    store.update(stored)
    host.onEvent(.peersChanged)
  }

  // MARK: - App pairing (6.3)

  private func startPairingAsPeripheral(_ link: Link) {
    guard host.canPrompt() else {
      reject(link, RejectReason.cannotPrompt)
      return
    }
    let pairing = Pairing(repair: store.key(link.peerId!) != nil)
    host.log("Pairing requested on link \(link.id) (repair=\(pairing.repair))")
    let keyPair = Crypto.generateEcKeyPair()
    pairing.keyPair = keyPair
    link.pairing = pairing
    link.phase = .pairing
    sendRecord(
      link, Record.encode(.pairCommit(commit: Derivation.commit(publicKeyP: keyPair.publicKey))),
      ProtocolEngine.priorityHandshake)
  }

  private func onPairingRecord(_ link: Link, _ record: Record) {
    guard let pairing = link.pairing else { return }
    switch record {
    case .pairCommit(let commit):
      guard link.role == .central, pairing.commit == nil else { return }
      pairing.commit = commit
      let keyPair = Crypto.generateEcKeyPair()
      pairing.keyPair = keyPair
      sendRecord(link, Record.encode(.pairKey(publicKey: keyPair.publicKey)), ProtocolEngine.priorityHandshake)
    case .pairKey(let publicKey):
      guard pairing.key == nil, let own = pairing.keyPair else { return }
      switch link.role {
      case .central:
        guard let commit = pairing.commit else { return }
        guard Crypto.constantTimeEquals(Derivation.commit(publicKeyP: publicKey), commit) else {
          reject(link, RejectReason.commitMismatch)
          return
        }
        derive(link, pairing, publicKeyP: publicKey, publicKeyC: own.publicKey)
      case .peripheral:
        sendRecord(link, Record.encode(.pairKey(publicKey: own.publicKey)), ProtocolEngine.priorityHandshake)
        derive(link, pairing, publicKeyP: own.publicKey, publicKeyC: publicKey)
      }
    case .pairConfirm(let mac):
      guard let key = pairing.key, !pairing.peerConfirmed else { return }
      let expected = Derivation.confirmMac(RawPeerKey(key: key), sender: link.peerId!, tPair: pairing.tPair!)
      guard Crypto.constantTimeEquals(expected, mac) else {
        reject(link, RejectReason.badMac)
        return
      }
      pairing.peerConfirmed = true
      finishPairingIfReady(link, pairing)
    default:
      host.log("Unexpected \(record) while pairing with \(link.deviceId)")
    }
  }

  private func derive(_ link: Link, _ pairing: Pairing, publicKeyP: Data, publicKeyC: Data) {
    let peerPublic = link.role == .central ? publicKeyP : publicKeyC
    guard let shared = Crypto.ecdh(pairing.keyPair!, peerPublicKey: peerPublic) else {
      reject(link, RejectReason.commitMismatch)
      return
    }
    let tPair = Derivation.tPair(tHello: link.tHello!, publicKeyP: publicKeyP, publicKeyC: publicKeyC)
    pairing.tPair = tPair
    pairing.key = Derivation.pairKey(sharedSecret: shared, tPair: tPair)
    let code = Derivation.code(tPair: tPair)
    pairing.code = code
    // Waiting for the users doesn't count against the handshake timeout.
    link.handshakeTimer?.cancel()
    pairing.approvalTimer = scheduler.schedule(ProtocolEngine.approvalTimeoutMs) { [unowned self] in
      if link.pairing === pairing && link.isLive {
        self.reject(link, RejectReason.timeout)
      }
    }
    host.onEvent(.pairingRequest(
      deviceId: link.deviceId, peerId: link.peerId!, name: link.peerName, code: code, repair: pairing.repair))
  }

  /// The user's answer to the pairing request for `deviceId`.
  @discardableResult
  func respondPairing(deviceId: String, accept: Bool) -> Bool {
    guard let link = links.values.first(where: {
      $0.isLive && $0.deviceId == deviceId && $0.pairing.map { $0.key != nil && !$0.localApproved } == true
    }), let pairing = link.pairing else { return false }
    if !accept {
      reject(link, RejectReason.userRejected)
      return true
    }
    pairing.localApproved = true
    let mac = Derivation.confirmMac(RawPeerKey(key: pairing.key!), sender: store.localPeerId, tPair: pairing.tPair!)
    sendRecord(link, Record.encode(.pairConfirm(mac: mac)), ProtocolEngine.priorityHandshake)
    finishPairingIfReady(link, pairing)
    return true
  }

  private func finishPairingIfReady(_ link: Link, _ pairing: Pairing) {
    guard pairing.localApproved, pairing.peerConfirmed else { return }
    pairing.approvalTimer?.cancel()
    let peerId = link.peerId!
    let hello = link.peerHello!
    store.savePaired(
      StoredPeer(peerId: peerId, name: hello.name ?? "", deviceId: link.deviceId, platform: hello.platform ?? 0, state: .paired),
      key: pairing.key!)
    link.pairing = nil
    host.onEvent(.pairingResult(deviceId: link.deviceId, peerId: peerId, result: ProtocolEngine.resultPaired))
    host.onEvent(.peersChanged)
    link.phase = .awaitAuth
    armHandshakeTimer(link)
    if link.role == .central {
      guard let key = store.key(peerId) else {
        host.onEvent(.error(message: "The pairing key for \(link.deviceId) could not be stored"))
        close(link)
        return
      }
      sendAuth(link, key)
    }
  }

  // MARK: - One link per peer (9절)

  /// Called once `link` knows its peer (from its HELLO): if another live link to the
  /// same peer exists, one of them goes. `proceed` continues `link`'s handshake if it
  /// stays, possibly later. See Engine.kt for the reasoning.
  private func resolveOtherLink(_ link: Link, _ proceed: @escaping () -> Void) {
    guard let peerId = link.peerId,
      let other = links.values.first(where: { $0 !== link && $0.isLive && $0.peerId == peerId })
    else {
      proceed()
      return
    }
    if other.phase != .established {
      let keepRole: Role = store.localPeerId < peerId ? .central : .peripheral
      if link.role == keepRole && other.role != keepRole {
        dropDuplicate(other)
        proceed()
      } else {
        dropDuplicate(link)
      }
      return
    }
    let generation = link.helloCount
    host.log("Checking the established link to \(other.deviceId) before accepting another")
    probe(other) { [unowned self] alive in
      guard link.isLive, link.helloCount == generation else { return }
      if alive {
        self.dropDuplicate(link)
      } else {
        self.host.log("The established link to \(other.deviceId) is dead; replacing it")
        self.dropDead(other)
        proceed()
      }
    }
  }

  /// Sends a `/ping` on `link`; `done` gets whether its ACK came back in time.
  private func probe(_ link: Link, _ done: @escaping (Bool) -> Void) {
    let msgId = store.nextMsgId()
    var finished = false
    var timer: Cancellable?
    let finish = { (alive: Bool) in
      guard !finished else { return }
      finished = true
      timer?.cancel()
      link.probes.removeValue(forKey: msgId)
      done(alive)
    }
    timer = scheduler.schedule(ProtocolEngine.probeTimeoutMs) { finish(false) }
    link.probes[msgId] = { finish(true) }
    let ping = DataEnvelope(
      msgId: msgId, flags: Envelope.flagAckReq, path: ProtocolEngine.pingPath, replyTo: 0, payload: Data())
    sendSealed(link, .data(ping), ProtocolEngine.priorityControl) { written in
      if !written {
        finish(false)
      }
    }
  }

  /// Ends an established `link` whose peer no longer answers.
  private func dropDead(_ link: Link) {
    switch link.role {
    case .central:
      close(link)
    case .peripheral:
      link.handshakeTimer?.cancel()
      endSession(link)
      link.phase = .done
      emitDisconnectedIfUnlinked(link.deviceId)
    }
  }

  private func dropDuplicate(_ link: Link) {
    host.log("Dropping the duplicate \(link.role.rawValue) link to \(link.deviceId)")
    switch link.role {
    case .central:
      close(link)
    case .peripheral:
      sendRecord(link, Record.encode(.reject(reason: RejectReason.alreadyConnected)), ProtocolEngine.priorityHandshake)
      link.handshakeTimer?.cancel()
      link.pairing?.approvalTimer?.cancel()
      link.pairing = nil
      link.phase = .done
    }
  }

  // MARK: - Sessions

  private func establish(_ link: Link, _ key: PeerKey) {
    let peerId = link.peerId!
    let tHello = link.tHello!
    link.handshakeTimer?.cancel()
    link.session = Session(
      sendKey: Derivation.sessionKey(key, from: store.localPeerId, to: peerId, tHello: tHello),
      receiveKey: Derivation.sessionKey(key, from: peerId, to: store.localPeerId, tHello: tHello))
    link.phase = .established
    host.log("Session with \(link.deviceId) on link \(link.id) (\(link.role.rawValue))")
    let hello = link.peerHello!
    let stored = store.peers().first { $0.peerId == peerId }
    let updated = StoredPeer(
      peerId: peerId,
      name: hello.name ?? stored?.name ?? "",
      deviceId: link.deviceId,
      platform: hello.platform ?? stored?.platform ?? 0,
      state: .paired)
    if updated != stored {
      store.update(updated)
    }
    let channel = channel(peerId)
    channel.link = link
    channel.maxMessageSize = min(Int64(hello.maxMessageSize ?? UInt32(maxMessageBytes)), Int64(maxMessageBytes))
    host.onEvent(.connected(deviceId: link.deviceId, peerId: peerId, name: link.peerName))
    host.onEvent(.peersChanged)
    sendCaps(channel)
    pumpChannel(channel)
  }

  /// Forgets `link`'s session; unacknowledged messages wait for the next one.
  private func endSession(_ link: Link) {
    guard link.session != nil else { return }
    link.session = nil
    guard let peerId = link.peerId, let channel = channels[peerId], channel.link === link else { return }
    channel.link = nil
    // 9절: resend the same msgIds, in their original order, on the next session.
    let pending = channel.inFlight
    channel.inFlight = []
    pending.forEach {
      $0.ackTimer?.cancel()
      $0.ackTimer = nil
    }
    channel.outbox.insert(contentsOf: pending, at: 0)
    host.onEvent(.peersChanged)
  }

  private func channel(_ peerId: PeerId) -> PeerChannel {
    if let existing = channels[peerId] {
      return existing
    }
    let created = PeerChannel(peerId: peerId)
    channels[peerId] = created
    return created
  }

  private func sendSealed(_ link: Link, _ envelope: Envelope, _ priority: Int, _ onWritten: ((Bool) -> Void)? = nil) {
    guard let session = link.session, !link.closed else {
      onWritten?(false)
      return
    }
    guard session.sendCounter <= UInt64(UInt32.max) else {
      // 5절: the counter can't wrap; a central starts a new session.
      if link.role == .central {
        close(link)
      }
      onWritten?(false)
      return
    }
    let counter = UInt32(session.sendCounter)
    session.sendCounter += 1
    let header = Record.sealedHeader(counter: counter)
    let body = Crypto.seal(key: session.sendKey, counter: counter, aad: header, plaintext: Envelope.encode(envelope))
    sendRecord(link, Record.encode(.sealed(counter: counter, body: body)), priority, onWritten)
  }

  private func onSealed(_ link: Link, counter: UInt32, body: Data) {
    guard let session = link.session, link.phase == .established, session.window.accepts(counter) else { return }
    guard let plain = Crypto.open(
      key: session.receiveKey, counter: counter, aad: Record.sealedHeader(counter: counter), sealed: body)
    else {
      session.decryptFailures += 1
      host.log("A SEALED record from \(link.deviceId) didn't decrypt")
      if session.decryptFailures >= ProtocolEngine.maxDecryptFailures && link.role == .central {
        host.onEvent(.error(message: "Too many undecryptable records from \(link.deviceId)"))
        close(link)
      }
      return
    }
    session.decryptFailures = 0
    session.window.mark(counter)
    let envelope: Envelope
    do {
      envelope = try Envelope.decode(plain)
    } catch {
      host.log("Dropped a malformed envelope from \(link.deviceId): \(error)")
      return
    }
    onEnvelope(link, channel(link.peerId!), envelope)
  }

  // MARK: - Delivery (7절, 9절)

  private func onEnvelope(_ link: Link, _ channel: PeerChannel, _ envelope: Envelope) {
    switch envelope {
    case .ack(let refMsgId, let status):
      if let probe = link.probes.removeValue(forKey: refMsgId) {
        probe()
        return
      }
      guard let outgoing = channel.removeInFlight(refMsgId) else { return }
      complete(outgoing, status)
      pumpChannel(channel)
    case .caps(let msgId, let builtins, let apps):
      guard Int64(msgId) >= channel.capsMsgId else { return }
      channel.caps = Capabilities(builtins: builtins, apps: apps)
      channel.capsMsgId = Int64(msgId)
      host.onEvent(.peersChanged)
      pumpChannel(channel)
    case .data(let data):
      onData(link, channel, data)
    case .unpair(let msgId):
      onUnpair(link, channel, msgId)
    case .unknown(_, let msgId, _):
      if envelope.ackRequested {
        sendSealed(link, .ack(refMsgId: msgId, status: DeliveryStatus.unsupported), ProtocolEngine.priorityAck)
      }
    }
  }

  private func onData(_ link: Link, _ channel: PeerChannel, _ data: DataEnvelope) {
    let ackRequested = data.flags & Envelope.flagAckReq != 0
    if data.path == ProtocolEngine.pingPath {
      if ackRequested {
        sendSealed(link, .ack(refMsgId: data.msgId, status: DeliveryStatus.ok), ProtocolEngine.priorityAck)
      }
      return
    }
    guard ackRequested else {
      host.deliver(peerId: channel.peerId, data: data) { _ in }
      return
    }
    let now = scheduler.now()
    channel.received = channel.received.filter { now - $0.value.at <= ProtocolEngine.dedupMs }
    if let seen = channel.received[data.msgId] {
      // A retransmission: don't deliver again, just repeat the ACK (once known).
      if let status = seen.status {
        sendSealed(link, .ack(refMsgId: data.msgId, status: status), ProtocolEngine.priorityAck)
      }
      return
    }
    let entry = Received(at: now)
    channel.received[data.msgId] = entry
    host.deliver(peerId: channel.peerId, data: data) { [unowned self] status in
      entry.status = status
      if let current = channel.link {
        self.sendSealed(current, .ack(refMsgId: data.msgId, status: status), ProtocolEngine.priorityAck)
      }
    }
  }

  private func onUnpair(_ link: Link, _ channel: PeerChannel, _ msgId: UInt32) {
    let peerId = channel.peerId
    host.log("UNPAIR from \(link.deviceId) on link \(link.id)")
    store.deleteKey(peerId)
    if var stored = store.peers().first(where: { $0.peerId == peerId }) {
      stored.state = .unpairedByPeer
      store.update(stored)
    }
    failOutbox(channel, DeliveryStatus.expiredNotSent)
    sendSealed(link, .ack(refMsgId: msgId, status: DeliveryStatus.ok), ProtocolEngine.priorityAck) { [unowned self] _ in
      // The central closes the link (7절); a peripheral just stops using it.
      if link.role == .central {
        self.close(link)
      } else if !link.closed {
        self.endSession(link)
        link.phase = .done
        self.emitDisconnectedIfUnlinked(link.deviceId)
      }
    }
    host.onEvent(.peerUnpaired(deviceId: link.deviceId, peerId: peerId))
    host.onEvent(.peersChanged)
  }

  /// Sends `payload` to `path` on `peerId`. `callback` gets an ACK status or a local
  /// result (`DeliveryStatus`) exactly once. Returns the msgId, or 0 if it failed
  /// right away. `app` is the sending app, checked against the peer's CAPS.
  @discardableResult
  func send(
    peerId: PeerId, path: String, payload: Data, replyTo: UInt32, ttlMs: Int64, app: AppIdentity?,
    callback: @escaping (Int) -> Void
  ) -> UInt32 {
    if path.isEmpty || path.utf8.count > Envelope.maxPathBytes {
      callback(DeliveryStatus.malformed)
      return 0
    }
    let control = path.hasPrefix("/control")
    let ttl = ttlMs <= 0
      ? (control ? ProtocolEngine.controlTtlMs : ProtocolEngine.defaultTtlMs)
      : min(ttlMs, ProtocolEngine.maxTtlMs)
    let msgId = store.nextMsgId()
    // A reply isn't acknowledged (9절).
    let flags = replyTo != 0 ? Envelope.flagReply : Envelope.flagAckReq
    let outgoing = Outgoing(
      msgId: msgId,
      envelope: .data(DataEnvelope(msgId: msgId, flags: flags, path: path, replyTo: replyTo, payload: payload)),
      priority: control ? ProtocolEngine.priorityControl : ProtocolEngine.priorityData,
      app: app,
      callback: callback)
    let channel = channel(peerId)
    channel.outbox.append(outgoing)
    outgoing.ttlTimer = scheduler.schedule(ttl) { [unowned self] in self.expire(channel, outgoing) }
    pumpChannel(channel)
    return msgId
  }

  private func pumpChannel(_ channel: PeerChannel) {
    guard let link = channel.link, link.phase == .established, !link.closed else { return }
    while channel.inFlight.count < ProtocolEngine.maxInFlight, let next = channel.outbox.first {
      if case .data(let data) = next.envelope {
        // Wait for the peer's CAPS (sent right after the session starts).
        guard let caps = channel.caps else { return }
        if !allows(caps, data.path, next.app) {
          channel.outbox.removeFirst()
          complete(next, DeliveryStatus.noReceiver)
          continue
        }
      }
      if Int64(Envelope.encode(next.envelope).count + ProtocolEngine.sealedOverhead) > channel.maxMessageSize {
        channel.outbox.removeFirst()
        complete(next, DeliveryStatus.tooLarge)
        continue
      }
      channel.outbox.removeFirst()
      channel.inFlight.append(next)
      sendSealed(link, next.envelope, next.priority) { [unowned self] written in
        self.onOutgoingWritten(channel, next, written)
      }
    }
  }

  private func onOutgoingWritten(_ channel: PeerChannel, _ outgoing: Outgoing, _ written: Bool) {
    guard !outgoing.done, channel.inFlight.contains(where: { $0 === outgoing }) else { return }
    if !written {
      // Try again shortly; if the link is going away, endSession requeues it anyway.
      _ = channel.removeInFlight(outgoing.msgId)
      channel.outbox.insert(outgoing, at: 0)
      if !channel.retryScheduled {
        channel.retryScheduled = true
        _ = scheduler.schedule(ProtocolEngine.retryDelayMs) { [unowned self] in
          channel.retryScheduled = false
          self.pumpChannel(channel)
        }
      }
      return
    }
    outgoing.written = true
    if !outgoing.envelope.ackRequested {
      _ = channel.removeInFlight(outgoing.msgId)
      complete(outgoing, DeliveryStatus.ok)
      pumpChannel(channel)
      return
    }
    outgoing.ackTimer?.cancel()
    outgoing.ackTimer = scheduler.schedule(ProtocolEngine.ackTimeoutMs) { [unowned self] in
      if !outgoing.done && channel.removeInFlight(outgoing.msgId) != nil {
        self.complete(outgoing, DeliveryStatus.expiredUnconfirmed)
        self.pumpChannel(channel)
      }
    }
  }

  private func allows(_ caps: Capabilities, _ path: String, _ app: AppIdentity?) -> Bool {
    if path.hasPrefix("/") {
      return caps.builtins.contains(path)
    }
    guard let app else { return false }
    return app.packageName == path.split(separator: "/", maxSplits: 1).first.map(String.init) && caps.apps.contains(app)
  }

  private func expire(_ channel: PeerChannel, _ outgoing: Outgoing) {
    guard !outgoing.done else { return }
    channel.outbox.removeAll { $0 === outgoing }
    _ = channel.removeInFlight(outgoing.msgId)
    complete(outgoing, outgoing.written ? DeliveryStatus.expiredUnconfirmed : DeliveryStatus.expiredNotSent)
    pumpChannel(channel)
  }

  private func complete(_ outgoing: Outgoing, _ status: Int) {
    guard !outgoing.done else { return }
    outgoing.done = true
    outgoing.ttlTimer?.cancel()
    outgoing.ackTimer?.cancel()
    outgoing.callback(status)
  }

  private func failOutbox(_ channel: PeerChannel, _ status: Int) {
    let pending = channel.outbox + channel.inFlight
    channel.outbox = []
    channel.inFlight = []
    pending.forEach { complete($0, status) }
  }

  private func sendCaps(_ channel: PeerChannel) {
    guard let link = channel.link else { return }
    let caps = host.localCaps()
    sendSealed(link, .caps(msgId: store.nextMsgId(), builtins: caps.builtins, apps: caps.apps), ProtocolEngine.priorityControl)
  }

  /// What this phone can receive changed; tell every connected peer.
  func capsChanged() {
    channels.values.filter { $0.link?.phase == .established }.forEach(sendCaps)
  }

  /// Forgets `peerId` (the user deleted it, 6.6): sends UNPAIR if connected and waits
  /// for its ACK (at most `unpairTimeoutMs`), then deletes K. `done` runs after that.
  func removePeer(_ peerId: PeerId, done: @escaping () -> Void) {
    let channel = channels[peerId]
    let link = channel?.link.flatMap { $0.phase == .established && !$0.closed ? $0 : nil }
    host.log("Removing \(peerId) (\(link.map { "UNPAIR on link \($0.id)" } ?? "not connected"))")
    guard let channel, let link else {
      forget(peerId)
      done()
      return
    }
    let msgId = store.nextMsgId()
    let unpair = Outgoing(
      msgId: msgId, envelope: .unpair(msgId: msgId), priority: ProtocolEngine.priorityControl, app: nil
    ) { [unowned self] _ in
      self.forget(peerId)
      if link.role == .central {
        self.close(link)
      } else if !link.closed {
        self.endSession(link)
        link.phase = .done
        self.emitDisconnectedIfUnlinked(link.deviceId)
      }
      done()
    }
    unpair.ttlTimer = scheduler.schedule(ProtocolEngine.unpairTimeoutMs) { [unowned self] in
      channel.outbox.removeAll { $0 === unpair }
      _ = channel.removeInFlight(msgId)
      self.complete(unpair, DeliveryStatus.expiredUnconfirmed)
    }
    // Ahead of queued messages; it's the last thing this peer gets.
    channel.outbox.insert(unpair, at: 0)
    pumpChannel(channel)
  }

  private func forget(_ peerId: PeerId) {
    if let channel = channels.removeValue(forKey: peerId) {
      failOutbox(channel, DeliveryStatus.expiredNotSent)
    }
    store.remove(peerId)
    host.onEvent(.peersChanged)
  }
}
