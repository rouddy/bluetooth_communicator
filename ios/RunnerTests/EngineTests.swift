import XCTest

@testable import Runner

/// The engine's flows, ported from Android's EngineTest.
final class EngineTests: XCTestCase {
  private var scheduler: FakeScheduler!
  private var network: Network!
  // A has the lower peerId, so it's "low" in the link tie-break.
  private var a: Phone!
  private var b: Phone!

  override func setUp() {
    scheduler = FakeScheduler()
    network = Network(scheduler: scheduler)
    a = network.phone("A", "AA:AA", PeerId(Data(repeating: 0x11, count: 16)))
    b = network.phone("B", "BB:BB", PeerId(Data(repeating: 0x77, count: 16)))
  }

  private func settle(_ ms: Int64 = 2_000) {
    scheduler.advance(ms)
  }

  /// A pairs with B from A's connect button, then both are connected.
  @discardableResult
  private func pair(settleMs: Int64 = 2_000) -> Network.Connection {
    let connection = network.connect(a, b, userInitiated: true)
    settle(settleMs)
    XCTAssertTrue(a.engine.isConnected(deviceId: b.address), "A connected")
    XCTAssertTrue(b.engine.isConnected(deviceId: a.address), "B connected")
    return connection
  }

  func testAppPairingShowsTheSameCodeOnBothPhonesAndStoresTheSameKey() {
    pair()

    guard case .pairingRequest(_, let peerIdA, let nameA, let codeA, let repairA) = a.pairingRequests.first,
      case .pairingRequest(_, _, let nameB, let codeB, _) = b.pairingRequests.first
    else { return XCTFail("no pairing requests") }
    XCTAssertEqual(codeA, codeB)
    XCTAssertEqual(codeA.count, 6)
    XCTAssertEqual(nameA, "B")
    XCTAssertEqual(nameB, "A")
    XCTAssertFalse(repairA)
    XCTAssertEqual(peerIdA, b.peerId)
    XCTAssertEqual(a.store.keys[b.peerId], b.store.keys[a.peerId])
    XCTAssertEqual(a.pairingResults, ["paired"])
    XCTAssertTrue(a.events.contains(.connected(deviceId: b.address, peerId: b.peerId, name: "B")))
    XCTAssertEqual(a.store.peers(), [StoredPeer(peerId: b.peerId, name: "B", deviceId: b.address, platform: Platform.ios, state: .paired)])
  }

  func testAReconnectAuthenticatesWithTheKeyAndAsksNobody() {
    pair().drop()
    a.events = []
    b.events = []

    network.connect(b, a)
    settle()

    XCTAssertTrue(a.engine.isConnected(deviceId: b.address))
    XCTAssertTrue(b.engine.isConnected(deviceId: a.address))
    XCTAssertTrue(a.pairingRequests.isEmpty)
    XCTAssertTrue(b.pairingRequests.isEmpty)
  }

  func testConnectingOnItsOwnToAPhoneWithoutAKeyIsRejectedWithoutAPrompt() {
    let connection = network.connect(a, b)
    settle()

    XCTAssertFalse(connection.open)
    XCTAssertTrue(a.events.contains(.peerRejected(deviceId: b.address, reason: RejectReason.unknownPeer, byPeer: false)))
    XCTAssertTrue(b.events.contains(.peerRejected(deviceId: a.address, reason: RejectReason.unknownPeer, byPeer: true)))
    XCTAssertTrue(a.pairingRequests.isEmpty)
    XCTAssertTrue(b.pairingRequests.isEmpty)
  }

  func testAPeerThatDeletedUsIsMarkedForRepairingWhichTheConnectButtonThenDoes() {
    pair().drop()
    b.store.remove(a.peerId)

    network.connect(a, b)
    settle()

    XCTAssertEqual(a.store.peers().first?.state, .repairNeeded)
    XCTAssertNotNil(a.store.key(b.peerId))
    XCTAssertFalse(a.engine.shouldReconnect(deviceId: b.address))

    a.events = []
    network.connect(a, b, userInitiated: true)
    settle()

    guard case .pairingRequest(_, _, _, _, let repair) = a.pairingRequests.first else { return XCTFail("no request") }
    XCTAssertTrue(repair)
    XCTAssertTrue(a.engine.isConnected(deviceId: b.address))
    XCTAssertEqual(a.store.peers().first?.state, .paired)
    XCTAssertEqual(a.store.keys[b.peerId], b.store.keys[a.peerId])
  }

  func testEitherUserCanDeclineThePairing() {
    b.approve = false
    let connection = network.connect(a, b, userInitiated: true)
    settle()

    XCTAssertFalse(connection.open)
    XCTAssertEqual(a.pairingResults, ["rejected"])
    XCTAssertEqual(b.pairingResults, ["rejected"])
    XCTAssertTrue(a.store.peers().isEmpty)
  }

  func testAnUnansweredPairingTimesOutAfter60Seconds() {
    b.approve = nil
    let connection = network.connect(a, b, userInitiated: true)
    settle(ProtocolEngine.handshakeTimeoutMs * 3)
    XCTAssertTrue(connection.open, "still waiting for B's user")

    settle(ProtocolEngine.approvalTimeoutMs)

    XCTAssertFalse(connection.open)
    XCTAssertEqual(a.pairingResults, ["timeout"])
    XCTAssertEqual(b.pairingResults, ["timeout"])
  }

  func testTheApprovalPromptIsListedUntilAnswered() {
    b.approve = nil
    network.connect(a, b, userInitiated: true)
    settle()

    XCTAssertEqual(b.engine.pendingApprovals().count, 1)
    XCTAssertTrue(b.engine.respondPairing(deviceId: a.address, accept: true))
    settle()
    XCTAssertTrue(b.engine.pendingApprovals().isEmpty)
    XCTAssertTrue(a.engine.isConnected(deviceId: b.address))
  }

  func testDataReachesThePeerAndIsAcknowledged() {
    pair()

    let results = a.send(to: b, Data("hello".utf8))
    settle()

    XCTAssertEqual(results.value, [DeliveryStatus.ok])
    XCTAssertEqual(b.delivered.map(\.payload), [Data("hello".utf8)])
  }

  func testAnAppMissingFromThePeersCapsFailsWithNoReceiver() {
    b.caps = Capabilities(builtins: [], apps: [])
    pair()

    let results = a.send(to: b, Data("x".utf8))
    settle()

    XCTAssertEqual(results.value, [DeliveryStatus.noReceiver])
    XCTAssertTrue(b.delivered.isEmpty)
  }

  func testLongMessagesSplitIntoFramesAndStayWithinAnAttributeValue() {
    for frameSize in [20, 514] {
      setUp()
      network.maxFrameSize = frameSize
      pair()
      let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 * 31) })

      let results = a.send(to: b, payload)
      settle(20_000)

      XCTAssertEqual(results.value, [DeliveryStatus.ok], "frames of \(frameSize)")
      XCTAssertEqual(b.delivered.first?.payload, payload)
    }
  }

  func testAMessageSentWhileThePeerIsAwayWaitsWithinTheTtl() {
    pair().drop()

    let results = a.send(to: b, Data("later".utf8))
    settle(5_000)
    XCTAssertTrue(results.value.isEmpty)
    network.connect(a, b)
    settle()

    XCTAssertEqual(results.value, [DeliveryStatus.ok])
  }

  func testAMessageThatCouldntBeSentExpiresAsNotSent() {
    pair().drop()

    let results = a.send(to: b, Data("never".utf8), ttlMs: 5_000)
    settle(10_000)

    XCTAssertEqual(results.value, [DeliveryStatus.expiredNotSent])
  }

  func testAnUnacknowledgedMessageIsResentOnTheNextSessionAndDeliveredOnce() {
    let connection = pair()
    b.deliverStatus = nil

    let results = a.send(to: b, Data("once".utf8))
    settle(500)
    XCTAssertEqual(b.delivered.count, 1)
    connection.drop()
    network.connect(a, b)
    settle(500)
    b.heldDeliveries.first?(DeliveryStatus.ok)
    settle()

    XCTAssertEqual(results.value, [DeliveryStatus.ok])
    XCTAssertEqual(b.delivered.count, 1)
  }

  func testDeletingAPeerSendsUnpairAndBothForgetTheKey() {
    let connection = pair()
    var done = false

    a.engine.removePeer(b.peerId) { done = true }
    settle()

    XCTAssertTrue(done)
    XCTAssertFalse(connection.open)
    XCTAssertTrue(a.store.peers().isEmpty)
    XCTAssertNil(b.store.key(a.peerId))
    XCTAssertEqual(b.store.peers().first?.state, .unpairedByPeer)
    XCTAssertTrue(b.events.contains(.peerUnpaired(deviceId: a.address, peerId: a.peerId)))
  }

  func testAnAuthThatDoesntVerifyStopsReconnectsOnBothSides() {
    pair().drop()
    b.store.keys[a.peerId] = Data(count: 32)

    network.connect(a, b)
    settle()

    XCTAssertEqual(a.store.peers().first?.state, .badMac)
    XCTAssertEqual(b.store.peers().first?.state, .badMac)
    XCTAssertFalse(a.engine.isConnected(deviceId: b.address))
  }

  func testTwoLinksMadeAtTheSameTimeEndAsOneWhoseCentralIsTheLowerPeerId() {
    pair().drop()

    let fromA = network.connect(a, b)
    let fromB = network.connect(b, a)
    settle()

    XCTAssertTrue(fromA.open)
    XCTAssertFalse(fromB.open)
    XCTAssertTrue(a.engine.isConnected(deviceId: b.address))
    XCTAssertTrue(b.engine.isConnected(deviceId: a.address))
    let results = b.send(to: a, Data("y".utf8))
    settle()
    XCTAssertEqual(results.value, [DeliveryStatus.ok])
  }

  func testASecondLinkToAConnectedPeerIsTurnedAwayAndTheFirstKeepsWorking() {
    let first = pair()
    let second = network.connect(b, a)
    settle()

    XCTAssertTrue(first.open)
    XCTAssertFalse(second.open)
    let results = b.send(to: a, Data("y".utf8))
    settle()
    XCTAssertEqual(results.value, [DeliveryStatus.ok])
  }

  func testAPeerWhoseAppRestartedUnderALiveConnectionReplacesItsDeadSession() {
    let old = pair()
    old.delivers = false
    let restarted = network.phone("B", b.address, b.peerId)
    b.store.peers().forEach { restarted.store.update($0) }
    restarted.store.keys = b.store.keys

    let fresh = network.connect(restarted, a)
    settle(ProtocolEngine.probeTimeoutMs + 2_000)

    XCTAssertTrue(fresh.open)
    XCTAssertTrue(a.engine.isConnected(deviceId: b.address))
    XCTAssertTrue(restarted.engine.isConnected(deviceId: a.address))
    let results = a.send(to: restarted, Data("hi".utf8))
    settle()
    XCTAssertEqual(results.value, [DeliveryStatus.ok])
  }
}
