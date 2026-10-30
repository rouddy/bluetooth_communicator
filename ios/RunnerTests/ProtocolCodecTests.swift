import XCTest

@testable import Runner

/// Codecs, frames, and crypto; mirrors CodecTest, FramesTest, and CryptoTest on Android.
final class ProtocolCodecTests: XCTestCase {
  private let peerId = PeerId(string: "00112233-4455-6677-8899-aabbccddeeff")!

  func testPeerIdRoundTripsThroughItsUuidFormAndOrdersUnsigned() {
    XCTAssertEqual(peerId.description, "00112233-4455-6677-8899-aabbccddeeff")
    XCTAssertEqual(peerId.bytes, Data(hex: "00112233445566778899aabbccddeeff"))
    let high = PeerId(Data([0x80] + [UInt8](repeating: 0, count: 15)))
    let low = PeerId(Data([0x7F] + [UInt8](repeating: 0, count: 15)))
    XCTAssertTrue(low < high)
  }

  func testHelloRoundTripsAndSkipsUnknownTags() throws {
    let hello = Hello(
      version: 1, peerId: peerId, nonce: Data(0..<16), name: "재홍의 S23", platform: Platform.android,
      appVersion: "1.0.0", maxMessageSize: 65_536)
    let bytes = Record.encode(.hello(hello)) + Data([0x7E, 2, 0, 9, 9])

    guard case .hello(let decoded) = try Record.decode(bytes) else { return XCTFail("not a HELLO") }

    XCTAssertEqual(decoded.peerId, peerId)
    XCTAssertEqual(decoded.nonce, Data(0..<16))
    XCTAssertEqual(decoded.name, "재홍의 S23")
    XCTAssertEqual(decoded.platform, Platform.android)
    XCTAssertEqual(decoded.maxMessageSize, 65_536)
  }

  func testHelloCutsLongNamesAtACharacter() throws {
    let bytes = Record.encode(.hello(Hello(version: 3, peerId: peerId, nonce: Data(count: 16), name: String(repeating: "가", count: 30))))
    XCTAssertEqual(bytes[0], 3)
    guard case .hello(let decoded) = try Record.decode(bytes) else { return XCTFail("not a HELLO") }
    XCTAssertEqual(decoded.name, String(repeating: "가", count: 21))
  }

  func testMalformedRecordsAreRejected() {
    var writer = ByteWriter()
    writer.u8(1)
    writer.u8(Record.helloType)
    Tlv.put(&writer, 0x01, peerId.bytes)
    XCTAssertThrowsError(try Record.decode(writer.data), "HELLO without a nonce")
    XCTAssertThrowsError(try Record.decode(Data([2, 0x02]) + Data(count: 32)), "another version")
    XCTAssertThrowsError(try Record.decode(Data([1, 0x02]) + Data(count: 33)), "trailing bytes")
  }

  func testFramesStayWithinTheSizeAndReassemble() {
    for maxFrameSize in [20, 23, 182, 512] {
      for size in [0, 1, 19, 20, 21, 100, 1000, 5000] {
        let record = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let frames = Frames.split(record, tid: 63, maxFrameSize: maxFrameSize)
        XCTAssertTrue(frames.allSatisfy { $0.count <= maxFrameSize })
        let reassembler = FrameReassembler(maxRecordSize: maxMessageBytes)
        XCTAssertEqual(frames.compactMap(reassembler.accept), [record], "size \(size) at \(maxFrameSize)")
      }
    }
  }

  func testFramesOfDifferentTidsMayInterleave() {
    let big = Data((0..<200).map { UInt8($0) })
    let small = Data([1, 2, 3])
    let bigFrames = Frames.split(big, tid: 1, maxFrameSize: 20)
    let reassembler = FrameReassembler(maxRecordSize: maxMessageBytes)
    var completed: [Data] = []
    completed += bigFrames.prefix(3).compactMap(reassembler.accept)
    completed += Frames.split(small, tid: 2, maxFrameSize: 20).compactMap(reassembler.accept)
    completed += bigFrames.dropFirst(3).compactMap(reassembler.accept)
    XCTAssertEqual(completed, [small, big])
  }

  func testBrokenFrameSequencesAreDropped() {
    let reassembler = FrameReassembler(maxRecordSize: 64)
    let frames = Frames.split(Data(count: 100), tid: 3, maxFrameSize: 20)
    XCTAssertTrue(frames.dropFirst().allSatisfy { reassembler.accept($0) == nil }, "no start")
    XCTAssertNil(reassembler.accept(Frames.split(Data(count: 65), tid: 0, maxFrameSize: 100)[0]), "over the limit")
    var start = ByteWriter()
    start.u8(Frames.start | 4)
    start.u32(30)
    start.append(Data(count: 15))
    XCTAssertNil(reassembler.accept(start.data))
    XCTAssertNil(reassembler.accept(Data([UInt8(Frames.end | 4)]) + Data(count: 5)), "short")
  }

  func testHmacMatchesRfc4231Case2() {
    XCTAssertEqual(
      Crypto.hmac(key: Data("Jefe".utf8), Data("what do ya want for nothing?".utf8)).hex,
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
  }

  func testHkdfMatchesRfc5869Case1() {
    let okm = Crypto.hkdf(
      ikm: Data(repeating: 0x0b, count: 22), salt: Data(hex: "000102030405060708090a0b0c")!,
      info: Data(hex: "f0f1f2f3f4f5f6f7f8f9")!, length: 42)
    XCTAssertEqual(okm.hex, "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
  }

  func testAesGcmOpensWhatItSealedAndNothingChanged() {
    let key = Data((0..<32).map { UInt8($0) })
    let aad = Record.sealedHeader(counter: 7)
    let sealed = Crypto.seal(key: key, counter: 7, aad: aad, plaintext: Data("hello".utf8))
    XCTAssertEqual(sealed.count, 5 + 16)
    XCTAssertEqual(Crypto.open(key: key, counter: 7, aad: aad, sealed: sealed), Data("hello".utf8))
    XCTAssertNil(Crypto.open(key: key, counter: 8, aad: Record.sealedHeader(counter: 8), sealed: sealed))
    XCTAssertNil(Crypto.open(key: Data(count: 32), counter: 7, aad: aad, sealed: sealed))
    var tampered = [UInt8](sealed)
    tampered[0] ^= 1
    XCTAssertNil(Crypto.open(key: key, counter: 7, aad: aad, sealed: Data(tampered)))
  }

  func testEcdhAgreesAndRejectsPointsOffTheCurve() {
    let alice = Crypto.generateEcKeyPair()
    let bob = Crypto.generateEcKeyPair()
    XCTAssertEqual(alice.publicKey.count, 65)
    let shared = Crypto.ecdh(alice, peerPublicKey: bob.publicKey)
    XCTAssertEqual(shared?.count, 32)
    XCTAssertEqual(shared, Crypto.ecdh(bob, peerPublicKey: alice.publicKey))
    var offCurve = [UInt8](bob.publicKey)
    offCurve[64] ^= 1
    XCTAssertNil(Crypto.ecdh(alice, peerPublicKey: Data(offCurve)))
    XCTAssertNil(Crypto.ecdh(alice, peerPublicKey: Data(count: 65)))
  }

  func testReplayWindowTakesNewAndOutOfOrderCountersOnce() {
    var window = ReplayWindow()
    for counter: UInt32 in [0, 2, 1, 5] {
      XCTAssertTrue(window.accepts(counter))
      window.mark(counter)
    }
    for counter: UInt32 in [0, 1, 2, 5] {
      XCTAssertFalse(window.accepts(counter))
    }
    XCTAssertTrue(window.accepts(3))
    window.mark(100)
    XCTAssertFalse(window.accepts(36))
    XCTAssertTrue(window.accepts(37))
  }
}
