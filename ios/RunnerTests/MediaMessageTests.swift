import XCTest

@testable import Runner

/// The `/control/media` codec, ported from Android's MediaMessageTest.
final class MediaMessageTests: XCTestCase {
  func testARequestIsTheOpByte() {
    XCTAssertEqual(MediaMessage.request(MediaMessage.opPlay), Data([1]))
    XCTAssertEqual(MediaMessage.decodeRequest(Data([5])), MediaMessage.opNext)
    XCTAssertNil(MediaMessage.decodeRequest(Data()))
    XCTAssertNil(MediaMessage.decodeRequest(Data([1, 2])))
  }

  func testOnlyTheOpsOfTheSpecAreKnown() {
    XCTAssertTrue(MediaMessage.isKnownOp(MediaMessage.opGetState))
    XCTAssertTrue(MediaMessage.isKnownOp(MediaMessage.opPrevious))
    XCTAssertFalse(MediaMessage.isKnownOp(7))
    XCTAssertEqual(MediaMessage.decodeRequest(Data([3])), MediaMessage.opPlayPause)
    XCTAssertEqual(MediaMessage.decodeRequest(Data([200])), 200)
  }

  func testAReplyCarriesTheResultAndTheState() {
    let payload = MediaMessage.reply(result: MediaMessage.ok, state: MediaMessage.statePlaying)
    XCTAssertEqual(payload, Data([0, 1]))
    let reply = MediaMessage.decodeReply(payload)
    XCTAssertEqual(reply?.result, MediaMessage.ok)
    XCTAssertEqual(reply?.state, MediaMessage.statePlaying)
    XCTAssertNil(MediaMessage.decodeReply(Data([0])))
  }

  func testNamesMatchThePlatformChannel() {
    XCTAssertEqual((0...6).map(MediaMessage.opName), ["getState", "play", "pause", "playPause", "stop", "next", "previous"])
    XCTAssertEqual(MediaMessage.op(named: "playPause"), MediaMessage.opPlayPause)
    XCTAssertNil(MediaMessage.op(named: "rewind"))
    XCTAssertEqual(MediaMessage.resultName(MediaMessage.unsupportedOp), "unsupportedOp")
    XCTAssertEqual(MediaMessage.stateName(MediaMessage.stateNotPlaying), "notPlaying")
    XCTAssertEqual(MediaMessage.stateName(MediaMessage.stateUnknown), "unknown")
  }
}
