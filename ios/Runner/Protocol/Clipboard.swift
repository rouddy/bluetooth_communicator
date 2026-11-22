import Foundation

/// The `/clipboard` built-in path (docs/protocol.md 10절); the Swift copy of
/// android/.../protocol/Clipboard.kt. The request is a DATA with `u8 op`; the answers
/// are REPLY DATAs with `u8 result` and, for `ok`, the text in UTF-8. A `waiting`
/// answer is followed by another one.
enum ClipboardMessage {
  static let path = "/clipboard"
  static let opGetText: UInt8 = 0

  static let ok = 0
  static let empty = 1
  /// Can't read it right now; the user on that phone was asked. Another reply follows.
  static let waiting = 2
  /// Can't read it right now and can't ask (e.g. the iOS app isn't on screen).
  static let unavailable = 3
  /// Clipboard sharing is off there, or its user didn't allow the read.
  static let denied = 4
  static let tooLarge = 5
  static let notText = 6

  /// Fits one message with the envelope and SEALED overhead (maxMessageBytes).
  static let maxTextBytes = 60_000

  struct Reply {
    let result: Int
    let text: String?
  }

  static func request() -> Data { Data([opGetText]) }

  /// Whether `payload` asks for the clipboard text (the only op in v1).
  static func isGetText(_ payload: Data) -> Bool { payload.count == 1 && payload.first == opGetText }

  static func reply(_ result: Int) -> Data { Data([UInt8(result)]) }

  /// The answer for the clipboard holding `text`: ok, empty, or tooLarge.
  static func replyWithText(_ text: String?) -> Data {
    guard let text, !text.isEmpty else { return reply(empty) }
    let bytes = Data(text.utf8)
    guard bytes.count <= maxTextBytes else { return reply(tooLarge) }
    return Data([UInt8(ok)]) + bytes
  }

  static func decodeReply(_ payload: Data) -> Reply? {
    guard let first = payload.first else { return nil }
    let result = Int(first)
    let text = result == ok ? String(decoding: payload.dropFirst(), as: UTF8.self) : nil
    return Reply(result: result, text: text)
  }

  /// Names for the platform channel (`clipboard.result`).
  static func resultName(_ result: Int) -> String {
    switch result {
    case ok: return "ok"
    case empty: return "empty"
    case waiting: return "waiting"
    case unavailable: return "unavailable"
    case denied: return "denied"
    case tooLarge: return "tooLarge"
    case notText: return "notText"
    default: return "unknown"
    }
  }
}
