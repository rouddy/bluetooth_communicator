import Foundation
import Security

/// This install's peerId, the msgId counter, and the app-paired peers (docs/protocol.md
/// 6.6). The peerId and each pair key K live in the Keychain, readable after the first
/// unlock (background reconnects while locked) and never moved to another device; the
/// peer list and the counter are in UserDefaults.
final class IOSPeerStore: PeerStore {
  private static let service = "com.rouddy.bluetooth_communicator.protocol"
  private static let installedKey = "rbc_installed"
  private static let peersKey = "rbc_peers"
  private static let msgIdKey = "rbc_msg_id"
  private static let peerIdAccount = "local_peer_id"

  private let defaults = UserDefaults.standard
  let localPeerId: PeerId
  private var stored: [StoredPeer]

  init() {
    // Keychain items survive uninstalling the app, UserDefaults don't. A fresh install
    // starts over, as on Android (a new peerId; peers see a new phone).
    if !defaults.bool(forKey: IOSPeerStore.installedKey) {
      IOSPeerStore.deleteAllItems()
      defaults.set(true, forKey: IOSPeerStore.installedKey)
    }
    if let existing = IOSPeerStore.read(IOSPeerStore.peerIdAccount), existing.count == PeerId.size {
      localPeerId = PeerId(existing)
    } else {
      localPeerId = PeerId.random()
      IOSPeerStore.write(IOSPeerStore.peerIdAccount, localPeerId.bytes)
    }
    stored = IOSPeerStore.loadPeers(defaults)
  }

  func nextMsgId() -> UInt32 {
    var next = UInt32(truncatingIfNeeded: defaults.integer(forKey: IOSPeerStore.msgIdKey)) &+ 1
    if next == 0 {
      next = 1
    }
    defaults.set(Int(next), forKey: IOSPeerStore.msgIdKey)
    return next
  }

  func peers() -> [StoredPeer] { stored }

  func key(_ peerId: PeerId) -> PeerKey? {
    IOSPeerStore.read(keyAccount(peerId)).map { RawPeerKey(key: $0) }
  }

  func savePaired(_ peer: StoredPeer, key: Data) {
    // A reinstalled peer gets a new peerId under the same identifier; replace it.
    stored.filter { $0.deviceId == peer.deviceId && $0.peerId != peer.peerId }.forEach { remove($0.peerId) }
    IOSPeerStore.write(keyAccount(peer.peerId), key)
    update(peer)
  }

  func update(_ peer: StoredPeer) {
    if let index = stored.firstIndex(where: { $0.peerId == peer.peerId }) {
      stored[index] = peer
    } else {
      stored.append(peer)
    }
    save()
  }

  func deleteKey(_ peerId: PeerId) {
    IOSPeerStore.delete(keyAccount(peerId))
  }

  func remove(_ peerId: PeerId) {
    deleteKey(peerId)
    stored.removeAll { $0.peerId == peerId }
    save()
  }

  private func keyAccount(_ peerId: PeerId) -> String { "key_\(peerId)" }

  private func save() {
    let array = stored.map {
      [
        "peerId": $0.peerId.description,
        "name": $0.name,
        "deviceId": $0.deviceId,
        "platform": $0.platform,
        "state": $0.state.rawValue,
      ] as [String: Any]
    }
    defaults.set(array, forKey: IOSPeerStore.peersKey)
  }

  private static func loadPeers(_ defaults: UserDefaults) -> [StoredPeer] {
    let array = defaults.array(forKey: peersKey) as? [[String: Any]] ?? []
    return array.compactMap { item in
      guard let peerIdText = item["peerId"] as? String, let peerId = PeerId(string: peerIdText),
        let deviceId = item["deviceId"] as? String
      else { return nil }
      return StoredPeer(
        peerId: peerId,
        name: item["name"] as? String ?? "",
        deviceId: deviceId,
        platform: item["platform"] as? Int ?? 0,
        state: PeerState(rawValue: item["state"] as? String ?? "") ?? .paired)
    }
  }

  // MARK: - Keychain

  private static func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  private static func read(_ account: String) -> Data? {
    var query = query(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }

  private static func write(_ account: String, _ data: Data) {
    delete(account)
    var item = query(account)
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    if status != errSecSuccess {
      NSLog("IOSPeerStore: storing \(account) failed (\(status))")
    }
  }

  private static func delete(_ account: String) {
    SecItemDelete(query(account) as CFDictionary)
  }

  private static func deleteAllItems() {
    SecItemDelete([
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ] as CFDictionary)
  }
}
