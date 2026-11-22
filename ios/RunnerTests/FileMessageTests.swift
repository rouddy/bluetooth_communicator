import XCTest

@testable import Runner

/// The `/file` codec, ported from Android's FileMessageTest.
final class FileMessageTests: XCTestCase {
  func testAnOfferCarriesTheSizeNameAndType() throws {
    guard case .offer(let size, let name, let mime)? = try FileMessage.decodeRequest(
      FileMessage.offer(size: 5_000_000_000, name: "사진.jpg", mime: "image/jpeg"))
    else { return XCTFail("not an offer") }
    XCTAssertEqual(size, 5_000_000_000)
    XCTAssertEqual(name, "사진.jpg")
    XCTAssertEqual(mime, "image/jpeg")
  }

  func testAChunkCarriesItsTransferAndOffset() throws {
    guard case .chunk(let transferId, let offset, let data)? = try FileMessage.decodeRequest(
      FileMessage.chunk(transferId: 0xFFFF_FFFF, offset: 1 << 40, data: Data([1, 2, 3])))
    else { return XCTFail("not a chunk") }
    XCTAssertEqual(transferId, 0xFFFF_FFFF)
    XCTAssertEqual(offset, 1 << 40)
    XCTAssertEqual(data, Data([1, 2, 3]))
    guard case .cancel(let canceled)? = try FileMessage.decodeRequest(FileMessage.cancel(transferId: 41)) else {
      return XCTFail("not a cancel")
    }
    XCTAssertEqual(canceled, 41)
  }

  func testAnUnknownOpIsNotMalformedABrokenOneIs() throws {
    XCTAssertNil(try FileMessage.decodeRequest(Data([9])))
    var emptyName = ByteWriter()
    emptyName.u8(FileMessage.opOffer)
    emptyName.u64(1)
    emptyName.u8(0)
    emptyName.u8(0)
    // A size from 2^63 up.
    var hugeSize = ByteWriter()
    hugeSize.u8(FileMessage.opOffer)
    hugeSize.u64(UInt64.max)
    hugeSize.u8(1)
    hugeSize.append(Data("a".utf8))
    hugeSize.u8(0)
    let broken = [
      Data(),
      FileMessage.offer(size: 1, name: "a", mime: "").prefix(5),
      FileMessage.chunk(transferId: 1, offset: 0, data: Data()),
      emptyName.data,
      hugeSize.data,
    ]
    for payload in broken {
      XCTAssertThrowsError(try FileMessage.decodeRequest(Data(payload)), "Decoded \(Data(payload).hex)")
    }
  }

  func testBytesAfterAnOfferAreLeftForLaterVersions() throws {
    let payload = FileMessage.offer(size: 3, name: "a.txt", mime: "text/plain") + Data([7, 7])
    guard case .offer(_, let name, _)? = try FileMessage.decodeRequest(payload) else { return XCTFail("not an offer") }
    XCTAssertEqual(name, "a.txt")
  }

  func testALongNameKeepsItsExtension() {
    let bytes = FileMessage.nameBytes(String(repeating: "가", count: 100) + ".jpg")
    XCTAssertLessThanOrEqual(bytes.count, FileMessage.maxNameBytes)
    XCTAssertEqual(String(decoding: bytes, as: UTF8.self), String(repeating: "가", count: 83) + ".jpg")
    // No extension worth keeping: just cut, on a character boundary.
    XCTAssertEqual(
      String(decoding: FileMessage.nameBytes(String(repeating: "가", count: 100)), as: UTF8.self),
      String(repeating: "가", count: 85))
    XCTAssertEqual(String(decoding: FileMessage.nameBytes("short.txt"), as: UTF8.self), "short.txt")
  }

  func testAReceivedNameCantLeaveItsDirectory() {
    XCTAssertEqual(FileMessage.safeFileName("../../etc/passwd"), "_.._etc_passwd")
    XCTAssertEqual(FileMessage.safeFileName("a\u{0}b\\c"), "a_b_c")
    XCTAssertEqual(FileMessage.safeFileName(".."), "file")
    XCTAssertEqual(FileMessage.safeFileName("  "), "file")
    XCTAssertEqual(FileMessage.safeFileName(".hidden"), "hidden")
    XCTAssertEqual(FileMessage.safeFileName("보고서 최종.pdf "), "보고서 최종.pdf")
  }

  func testOnlyAPlainTypePassesAsTheMimeType() {
    XCTAssertEqual(FileMessage.safeMime("image/JPEG"), "image/jpeg")
    XCTAssertEqual(FileMessage.safeMime("application/vnd.ms-excel"), "application/vnd.ms-excel")
    for mime in ["", "text", "/plain", "text/", "a/b/c", "text/plain; charset=utf-8"] {
      XCTAssertEqual(FileMessage.safeMime(mime), FileMessage.defaultMime, mime)
    }
  }

  func testTheLargestChunkFitsOneMessage() {
    let payload = FileMessage.chunk(transferId: 0xFFFF_FFFF, offset: Int64.max, data: Data(count: FileMessage.chunkSize))
    let envelope = Envelope.encode(.data(DataEnvelope(
      msgId: 0xFFFF_FFFF, flags: Envelope.flagAckReq, path: FileMessage.path, replyTo: 0, payload: payload)))
    XCTAssertLessThanOrEqual(envelope.count + ProtocolEngine.sealedOverhead, maxMessageBytes)
  }

  func testRepliesAreOneResultByte() {
    XCTAssertEqual(FileMessage.decodeReply(FileMessage.reply(FileMessage.declined)), FileMessage.declined)
    XCTAssertNil(FileMessage.decodeReply(Data()))
  }
}
