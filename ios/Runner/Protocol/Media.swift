import Foundation

/// The `/control/media` built-in path (docs/protocol.md 10절); the Swift copy of
/// android/.../protocol/Media.kt. The request is a DATA with `u8 op`; the answer is a
/// REPLY DATA with `u8 result` and `u8 state`. iOS can't control other apps' playback,
/// so it only sends these (it doesn't list the path in its CAPS).
enum MediaMessage {
  static let path = "/control/media"

  static let opGetState = 0
  static let opPlay = 1
  static let opPause = 2
  static let opPlayPause = 3
  static let opStop = 4
  static let opNext = 5
  static let opPrevious = 6

  static let ok = 0
  static let failed = 1
  static let unsupportedOp = 2

  static let stateUnknown = 0
  static let statePlaying = 1
  static let stateNotPlaying = 2

  struct Reply {
    let result: Int
    let state: Int
  }

  static func request(_ op: Int) -> Data { Data([UInt8(op)]) }

  /// The op `payload` asks for, or nil if it isn't a request.
  static func decodeRequest(_ payload: Data) -> Int? { payload.count == 1 ? Int(payload[payload.startIndex]) : nil }

  static func isKnownOp(_ op: Int) -> Bool { (opGetState...opPrevious).contains(op) }

  static func reply(result: Int, state: Int) -> Data { Data([UInt8(result), UInt8(state)]) }

  static func decodeReply(_ payload: Data) -> Reply? {
    guard payload.count >= 2 else { return nil }
    let bytes = [UInt8](payload)
    return Reply(result: Int(bytes[0]), state: Int(bytes[1]))
  }

  private static let opNames = ["getState", "play", "pause", "playPause", "stop", "next", "previous"]

  /// Names for the platform channel (`controlMedia.op`, `mediaControl.op`).
  static func opName(_ op: Int) -> String { opNames.indices.contains(op) ? opNames[op] : "unknown" }

  static func op(named name: String) -> Int? { opNames.firstIndex(of: name) }

  /// Names for the platform channel (`mediaControl.result`).
  static func resultName(_ result: Int) -> String {
    switch result {
    case ok: return "ok"
    case failed: return "failed"
    case unsupportedOp: return "unsupportedOp"
    default: return "unknown"
    }
  }

  /// Names for the platform channel (`mediaControl.state`).
  static func stateName(_ state: Int) -> String {
    switch state {
    case statePlaying: return "playing"
    case stateNotPlaying: return "notPlaying"
    default: return "unknown"
    }
  }
}
