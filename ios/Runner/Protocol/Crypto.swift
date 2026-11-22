import CryptoKit
import Foundation

/// A pair key K. It's only ever used as an HMAC key (6.4).
protocol PeerKey {
  func hmac(_ data: Data) -> Data
}

struct RawPeerKey: PeerKey {
  let key: Data

  func hmac(_ data: Data) -> Data { Crypto.hmac(key: key, data) }
}

/// SHA-256, HMAC-SHA256, HKDF, AES-256-GCM, and P-256 ECDH, from CryptoKit.
enum Crypto {
  static let keySize = 32

  static func sha256(_ parts: Data...) -> Data {
    var hash = SHA256()
    parts.forEach { hash.update(data: $0) }
    return Data(hash.finalize())
  }

  static func hmac(key: Data, _ parts: Data...) -> Data {
    var mac = HMAC<SHA256>(key: SymmetricKey(data: key))
    parts.forEach { mac.update(data: $0) }
    return Data(mac.finalize())
  }

  /// RFC 5869 with SHA-256.
  static func hkdf(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
    let key = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: length)
    return key.withUnsafeBytes { Data($0) }
  }

  /// `counter (u32 LE) ‖ 0x00 × 8` (5절).
  static func nonce(counter: UInt32) -> Data {
    var writer = ByteWriter()
    writer.u32(counter)
    writer.append(Data(count: 8))
    return writer.data
  }

  /// Returns the ciphertext followed by the 16-byte tag.
  static func seal(key: Data, counter: UInt32, aad: Data, plaintext: Data) -> Data {
    // Only fails for a nonce or key of the wrong size, which can't happen here.
    let box = try! AES.GCM.seal(
      plaintext, using: SymmetricKey(data: key),
      nonce: try! AES.GCM.Nonce(data: nonce(counter: counter)), authenticating: aad)
    return box.ciphertext + box.tag
  }

  /// Returns nil if the tag doesn't verify.
  static func open(key: Data, counter: UInt32, aad: Data, sealed: Data) -> Data? {
    guard sealed.count >= Record.gcmTagSize,
      let nonce = try? AES.GCM.Nonce(data: nonce(counter: counter)),
      let box = try? AES.GCM.SealedBox(
        nonce: nonce,
        ciphertext: sealed.prefix(sealed.count - Record.gcmTagSize),
        tag: sealed.suffix(Record.gcmTagSize))
    else { return nil }
    return try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
  }

  static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for (x, y) in zip(a, b) {
      difference |= x ^ y
    }
    return difference == 0
  }

  /// A P-256 key pair; `publicKey` is the X9.62 uncompressed point (65 bytes).
  struct EcKeyPair {
    let privateKey: P256.KeyAgreement.PrivateKey

    var publicKey: Data { privateKey.publicKey.x963Representation }
  }

  static func generateEcKeyPair() -> EcKeyPair {
    EcKeyPair(privateKey: P256.KeyAgreement.PrivateKey())
  }

  /// The ECDH shared secret (the x coordinate, 32 bytes), or nil if
  /// `peerPublicKey` isn't a valid point on P-256 (CryptoKit checks).
  static func ecdh(_ own: EcKeyPair, peerPublicKey: Data) -> Data? {
    guard peerPublicKey.count == Record.publicKeySize,
      let peer = try? P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey),
      let shared = try? own.privateKey.sharedSecretFromKeyAgreement(with: peer)
    else { return nil }
    return shared.withUnsafeBytes { Data($0) }
  }
}

/// The receive side's replay protection for SEALED counters (5절): the highest counter
/// seen plus a bitmap of the 64 below it.
struct ReplayWindow {
  private var highest: Int64 = -1
  private var seen: UInt64 = 0

  /// Whether `counter` is new and not older than the window.
  func accepts(_ counter: UInt32) -> Bool {
    let value = Int64(counter)
    if value > highest {
      return true
    }
    let age = highest - value
    return age < 64 && (seen >> UInt64(age)) & 1 == 0
  }

  /// Records `counter`; call only after the record decrypted.
  mutating func mark(_ counter: UInt32) {
    let value = Int64(counter)
    if value > highest {
      let shift = value - highest
      seen = shift >= 64 ? 0 : seen << UInt64(shift)
      seen |= 1
      highest = value
    } else {
      seen |= 1 << UInt64(highest - value)
    }
  }
}
