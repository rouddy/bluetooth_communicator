import XCTest

@testable import Runner

/// test_vectors/protocol_v1.json, shared with Android's VectorsTest and generated from
/// the spec by test_vectors/generate.py: both platforms must produce these bytes.
final class VectorsTests: XCTestCase {
  private var vectors: [String: Any] = [:]
  private var handshake: [String: Any] { vectors["handshake"] as! [String: Any] }

  override func setUpWithError() throws {
    // Read from the source tree: tests run on the simulator (or macOS), which sees it.
    let url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("test_vectors/protocol_v1.json")
    let data = try Data(contentsOf: url)
    vectors = try JSONSerialization.jsonObject(with: data) as! [String: Any]
  }

  private func hex(_ object: Any?, _ key: String) -> Data {
    Data(hex: (object as! [String: Any])[key] as! String)!
  }

  private func hello(_ key: String, _ peerId: PeerId) -> Hello {
    let json = handshake[key] as! [String: Any]
    return Hello(
      version: 1, peerId: peerId, nonce: hex(json, "nonce"), name: json["name"] as? String,
      platform: json["platform"] as? Int, appVersion: json["appVersion"] as? String,
      maxMessageSize: UInt32(json["maxMessageSize"] as! Int))
  }

  func testHelloEncodesToTheSharedBytes() throws {
    let peerC = PeerId(hex(handshake, "peerIdC"))
    XCTAssertEqual(Record.encode(.hello(hello("helloC", peerC))), hex(handshake["helloC"], "bytes"))
    guard case .hello(let decoded) = try Record.decode(hex(handshake["helloP"], "bytes")) else {
      return XCTFail("not a HELLO")
    }
    XCTAssertEqual(decoded.peerId, PeerId(hex(handshake, "peerIdP")))
    XCTAssertEqual(decoded.name, "RouddySE")
    XCTAssertEqual(decoded.platform, Platform.ios)
  }

  func testTheHandshakeDerivationsMatch() throws {
    let peerC = PeerId(hex(handshake, "peerIdC"))
    let peerP = PeerId(hex(handshake, "peerIdP"))
    let key = RawPeerKey(key: hex(handshake, "pairKey"))
    let tHello = Derivation.tHello(helloC: hex(handshake["helloC"], "bytes"), helloP: hex(handshake["helloP"], "bytes"))
    XCTAssertEqual(tHello, hex(handshake, "tHello"))
    let publicP = hex(handshake, "publicKeyP")
    let publicC = hex(handshake, "publicKeyC")
    XCTAssertEqual(Derivation.commit(publicKeyP: publicP), hex(handshake, "commit"))
    let privateC = try Crypto.EcKeyPair(
      privateKey: .init(rawRepresentation: hex(handshake, "privateKeyC")))
    let privateP = try Crypto.EcKeyPair(
      privateKey: .init(rawRepresentation: hex(handshake, "privateKeyP")))
    XCTAssertEqual(privateC.publicKey, publicC)
    XCTAssertEqual(privateP.publicKey, publicP)
    XCTAssertEqual(Crypto.ecdh(privateC, peerPublicKey: publicP), hex(handshake, "sharedSecret"))
    XCTAssertEqual(Crypto.ecdh(privateP, peerPublicKey: publicC), hex(handshake, "sharedSecret"))
    let tPair = Derivation.tPair(tHello: tHello, publicKeyP: publicP, publicKeyC: publicC)
    XCTAssertEqual(tPair, hex(handshake, "tPair"))
    XCTAssertEqual(Derivation.pairKey(sharedSecret: hex(handshake, "sharedSecret"), tPair: tPair), hex(handshake, "pairKey"))
    XCTAssertEqual(Derivation.code(tPair: tPair), handshake["code"] as? String)
    XCTAssertEqual(Derivation.confirmMac(key, sender: peerC, tPair: tPair), hex(handshake, "confirmMacC"))
    XCTAssertEqual(Derivation.confirmMac(key, sender: peerP, tPair: tPair), hex(handshake, "confirmMacP"))
    XCTAssertEqual(Derivation.authMac(key, sender: peerC, tHello: tHello), hex(handshake, "authMacC"))
    XCTAssertEqual(Derivation.authMac(key, sender: peerP, tHello: tHello), hex(handshake, "authMacP"))
    XCTAssertEqual(Derivation.sessionKey(key, from: peerC, to: peerP, tHello: tHello), hex(handshake, "sessionKeyCtoP"))
    XCTAssertEqual(Derivation.sessionKey(key, from: peerP, to: peerC, tHello: tHello), hex(handshake, "sessionKeyPtoC"))
  }

  func testASealedRecordEncryptsToTheSharedBytesAndBack() throws {
    let sealed = vectors["sealed"] as! [String: Any]
    let counter = UInt32(sealed["counter"] as! Int)
    let body = Crypto.seal(
      key: hex(sealed, "key"), counter: counter, aad: Record.sealedHeader(counter: counter), plaintext: hex(sealed, "envelope"))
    XCTAssertEqual(Record.encode(.sealed(counter: counter, body: body)), hex(sealed, "record"))
    guard case .sealed(let decodedCounter, let decodedBody) = try Record.decode(hex(sealed, "record")) else {
      return XCTFail("not SEALED")
    }
    XCTAssertEqual(
      Crypto.open(key: hex(sealed, "key"), counter: decodedCounter, aad: Record.sealedHeader(counter: decodedCounter), sealed: decodedBody),
      hex(sealed, "envelope"))
  }

  func testEnvelopesAndRecordsEncodeToTheSharedBytes() throws {
    let envelopes = vectors["envelopes"]
    let app = AppIdentity(packageName: "com.example.app", certHash: String(repeating: "ab", count: 32))
    let cases: [(String, Envelope)] = [
      ("dataRequest", .data(DataEnvelope(msgId: 41, flags: Envelope.flagAckReq, path: "/control/media", replyTo: 0, payload: Data([1])))),
      ("dataReply", .data(DataEnvelope(msgId: 7, flags: Envelope.flagReply, path: "/control/media", replyTo: 41, payload: Data([0, 1])))),
      ("ack", .ack(refMsgId: 41, status: DeliveryStatus.noReceiver)),
      ("caps", .caps(msgId: 9, builtins: ["/control/media"], apps: [app])),
      ("unpair", .unpair(msgId: 10)),
    ]
    for (name, envelope) in cases {
      XCTAssertEqual(Envelope.encode(envelope), hex(envelopes, name), name)
      XCTAssertEqual(Envelope.encode(try Envelope.decode(hex(envelopes, name))), hex(envelopes, name), name)
    }
    let records = vectors["records"]
    XCTAssertEqual(Record.encode(.auth(mac: Data(repeating: 0xAA, count: 32))), hex(records, "auth"))
    XCTAssertEqual(Record.encode(.pairRequest), hex(records, "pairRequest"))
    XCTAssertEqual(Record.encode(.reject(reason: RejectReason.alreadyConnected)), hex(records, "reject"))
  }

  func testARecordSplitsIntoTheSharedFrames() {
    let frames = vectors["frames"] as! [String: Any]
    let expected = (frames["frames"] as! [String]).map { Data(hex: $0)! }
    let actual = Frames.split(hex(frames, "record"), tid: frames["tid"] as! Int, maxFrameSize: frames["maxFrameSize"] as! Int)
    XCTAssertEqual(actual, expected)
    let reassembler = FrameReassembler(maxRecordSize: maxMessageBytes)
    XCTAssertEqual(actual.compactMap(reassembler.accept), [hex(frames, "record")])
  }
}
