import Flutter
import CoreBluetooth
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let methodChannelName = "com.rouddy.bluetooth_communicator/bluetooth_control"
  private let eventChannelName = "com.rouddy.bluetooth_communicator/bluetooth_events"
  private let bleManager = IOSBleBackgroundManager()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // With the UIScene lifecycle the window (and its FlutterViewController) doesn't
  // exist yet in didFinishLaunchingWithOptions, so the channels are registered on
  // the implicit engine's messenger instead.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerBleChannels(messenger: engineBridge.applicationRegistrar.messenger())
  }

  private func registerBleChannels(messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: messenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "NO_APP", message: "App unavailable", details: nil))
        return
      }
      switch call.method {
      case "initialize":
        // Like Android: whether the Bluetooth permission is granted. Dart requests it
        // (permission_handler) before calling this.
        self.bleManager.restoreState()
        result(CBManager.authorization == .allowedAlways)
      case "setAdvertisingEnabled":
        let args = call.arguments as? [String: Any]
        let enabled = (args?["enabled"] as? Bool) ?? false
        self.bleManager.setAdvertisingEnabled(enabled)
        result(nil)
      case "setCentralEnabled":
        let args = call.arguments as? [String: Any]
        let enabled = (args?["enabled"] as? Bool) ?? false
        self.bleManager.setCentralEnabled(enabled)
        result(nil)
      case "scanNow":
        self.bleManager.scanNow()
        result(nil)
      case "connectDevice":
        let args = call.arguments as? [String: Any]
        self.bleManager.connectDevice(args?["deviceId"] as? String, pair: (args?["pair"] as? Bool) ?? false)
        result(nil)
      case "removeDevice":
        let args = call.arguments as? [String: Any]
        self.bleManager.removeDevice(args?["deviceId"] as? String)
        result(nil)
      case "respondPairing":
        let args = call.arguments as? [String: Any]
        self.bleManager.respondPairing(args?["deviceId"] as? String, accept: (args?["accept"] as? Bool) ?? false)
        result(nil)
      case "setDeviceName":
        let args = call.arguments as? [String: Any]
        self.bleManager.setDeviceName(args?["name"] as? String)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(
      name: eventChannelName,
      binaryMessenger: messenger
    )
    eventChannel.setStreamHandler(bleManager)
  }
}

/// Engine timers on the main queue, where every CoreBluetooth and channel callback runs.
final class MainQueueScheduler: EngineScheduler {
  private final class Work: Cancellable {
    let item: DispatchWorkItem

    init(_ item: DispatchWorkItem) {
      self.item = item
    }

    func cancel() {
      item.cancel()
    }
  }

  func now() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

  func schedule(_ delayMs: Int64, _ action: @escaping () -> Void) -> Cancellable {
    let item = DispatchWorkItem(block: action)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: item)
    return Work(item)
  }
}

/// Owns the CoreBluetooth managers and carries the protocol's frames for the engine
/// (the iOS side of docs/protocol.md): one link per connected peripheral whose
/// characteristic we subscribed to (we're central), and one per central subscribed to
/// our service (we're peripheral). Everything runs on the main queue.
final class IOSBleBackgroundManager: NSObject, FlutterStreamHandler, EngineHost {
  private let serviceUUID = CBUUID(string: "1F9ED31D-B738-4D4C-A6D8-86DBF0F9C001")
  // Protocol v1 frames. Changed from the raw-UTF-8 chat characteristic (DB912050-…)
  // so old and new builds don't misread each other (14절).
  private let frameCharacteristicUUID = CBUUID(string: "002069AC-115D-4391-8772-13E44DF757FC")
  private let prefs = UserDefaults.standard
  private let deviceNameKey = "rbc_device_name"
  private let peripheralIdsKey = "rbc_peripheral_ids"

  private let store = IOSPeerStore()
  private let scheduler = MainQueueScheduler()
  private lazy var engine = ProtocolEngine(host: self, store: store, scheduler: scheduler)

  private lazy var centralManager: CBCentralManager = {
    CBCentralManager(
      delegate: self,
      queue: nil,
      options: [CBCentralManagerOptionRestoreIdentifierKey: "ble.central.restore"]
    )
  }()
  private lazy var peripheralManager: CBPeripheralManager = {
    CBPeripheralManager(
      delegate: self,
      queue: nil,
      options: [CBPeripheralManagerOptionRestoreIdentifierKey: "ble.peripheral.restore"]
    )
  }()

  private var eventSink: FlutterEventSink?

  // Engine links: a client link per peripheral identifier, a server link per central
  // identifier. A peer reached in both roles has two (the engine keeps one, 9절).
  private enum LinkTarget {
    case client(UUID)
    case server(UUID)
  }

  private var linkTargets: [Int: LinkTarget] = [:]
  private var clientLinkIds: [UUID: Int] = [:]
  private var serverLinkIds: [UUID: Int] = [:]
  private var nextLinkId = 1

  // Central role.
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var characteristics: [UUID: CBCharacteristic] = [:]
  // Peripherals the user asked to connect to (the 연결 button). Only those links may
  // start an app pairing (6.3). Kept for the whole connection, since the peer
  // re-registering its GATT server (didModifyServices) restarts the handshake on it;
  // cleared once a session is up or the connection ends.
  private var userInitiated: Set<UUID> = []
  // Peripherals of deleted devices: not reconnected until 연결 is pressed again.
  private var forgottenPeripherals: Set<UUID> = []
  // connectDevice calls made before the central manager was powered on.
  private var pendingConnectIds: Set<UUID> = []
  // Subscription retries per peripheral while pairing is in progress.
  private var subscribeAttempts: [UUID: Int] = [:]
  // peerId → the peripheral identifier we reached it under as a central. A peer that
  // connects to us shows up under another identifier (its CBCentral's).
  private var peripheralIds: [String: String]

  // Peripheral role.
  private var frameCharacteristic: CBMutableCharacteristic?
  private var serviceAdded = false
  private var addingService = false
  private var subscribedCentrals: [UUID: CBCentral] = [:]
  private var pendingNotifications: [(linkId: Int, data: Data, central: CBCentral)] = []

  private var advertisingEnabled = false
  private var centralEnabled = false
  // What's reported in `status`. Tracked from delegate callbacks rather than read off
  // the managers: they're lazy, and touching them early shows the Bluetooth prompt.
  private var isAdvertising = false
  private var isScanning = false
  private var bluetoothOn = true

  override init() {
    peripheralIds = UserDefaults.standard.dictionary(forKey: "rbc_peripheral_ids") as? [String: String] ?? [:]
    super.init()
    // The chat's undelivered messages; the chat is gone.
    prefs.removeObject(forKey: "pending_messages")
  }

  // MARK: - Flutter

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    emitStatus()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func restoreState() {
    advertisingEnabled = prefs.bool(forKey: "pref_ios_advertising")
    centralEnabled = prefs.bool(forKey: "pref_ios_central")
    if advertisingEnabled {
      startAdvertisingIfPossible()
    }
    if centralEnabled {
      startScanningIfPossible()
      reconnectPeers()
    }
    // A newly attached Dart side learns the sessions, peers, and pending prompts.
    engine.connectedSessions().forEach(emitDartEvent)
    emitPeers()
    engine.pendingApprovals().forEach(emitDartEvent)
    emitStatus()
  }

  func setAdvertisingEnabled(_ enabled: Bool) {
    advertisingEnabled = enabled
    prefs.set(enabled, forKey: "pref_ios_advertising")
    if enabled {
      startAdvertisingIfPossible()
    } else {
      peripheralManager.stopAdvertising()
      isAdvertising = false
      peripheralManager.removeAllServices()
      resetPeripheralRole()
      emitStatus()
    }
  }

  func setCentralEnabled(_ enabled: Bool) {
    centralEnabled = enabled
    prefs.set(enabled, forKey: "pref_ios_central")
    if enabled {
      startScanningIfPossible()
      reconnectPeers()
    } else {
      centralManager.stopScan()
      isScanning = false
      // Like Android: turning central mode off drops the links we made as central.
      peripherals.values.filter { $0.state != .disconnected }.forEach { centralManager.cancelPeripheralConnection($0) }
      emitStatus()
    }
  }

  func scanNow() {
    guard centralEnabled else { return }
    startScanningIfPossible()
  }

  /// iOS 16+ reports every phone as "iPhone" without an entitlement, so the user names
  /// it (HELLO and the advertised name use it).
  func setDeviceName(_ name: String?) {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    log("Device name: \(trimmed.isEmpty ? "(default)" : trimmed)")
    if trimmed.isEmpty {
      prefs.removeObject(forKey: deviceNameKey)
    } else {
      prefs.set(trimmed, forKey: deviceNameKey)
    }
    if isAdvertising {
      peripheralManager.stopAdvertising()
      isAdvertising = false
      startAdvertisingIfPossible()
    }
  }

  private var deviceName: String {
    prefs.string(forKey: deviceNameKey) ?? UIDevice.current.name
  }

  func connectDevice(_ deviceId: String?, pair: Bool) {
    guard let deviceId, let uuid = UUID(uuidString: deviceId) else { return }
    forgottenPeripherals.remove(uuid)
    if pair {
      userInitiated.insert(uuid)
    }
    guard centralManager.state == .poweredOn else {
      pendingConnectIds.insert(uuid)
      return
    }
    // After a relaunch a saved device isn't in `peripherals` until it's scanned again,
    // but CoreBluetooth can still hand it out by identifier.
    guard let peripheral = peripherals[uuid] ?? centralManager.retrievePeripherals(withIdentifiers: [uuid]).first else {
      emit(type: "error", payload: ["message": "Unknown device \(deviceId)"])
      emitDisconnected(deviceId)
      return
    }
    peripherals[uuid] = peripheral
    switch peripheral.state {
    case .disconnected:
      centralManager.connect(peripheral, options: nil)
    case .connected where !engine.hasLiveLink(deviceId: deviceId):
      // Still connected (e.g. its last link was turned away): a new handshake is enough.
      if let characteristic = characteristics[uuid], characteristic.isNotifying {
        clientLinkUp(uuid)
      } else {
        peripheral.discoverServices([serviceUUID])
      }
    default:
      break
    }
  }

  /// Deletes the peer (UNPAIR first if connected, 6.6), then drops our link to it.
  func removeDevice(_ deviceId: String?) {
    guard let deviceId else { return }
    let peers = store.peers().filter {
      $0.deviceId == deviceId || peripheralIds[$0.peerId.description] == deviceId
    }
    guard !peers.isEmpty else {
      disconnect(deviceId)
      return
    }
    var remaining = peers.count
    for peer in peers {
      let known = peripheralIds.removeValue(forKey: peer.peerId.description)
      prefs.set(peripheralIds, forKey: peripheralIdsKey)
      engine.removePeer(peer.peerId) { [weak self] in
        remaining -= 1
        if remaining == 0 {
          self?.disconnect(deviceId)
          known.map { self?.disconnect($0) }
        }
      }
    }
  }

  func respondPairing(_ deviceId: String?, accept: Bool) {
    guard let deviceId else { return }
    engine.respondPairing(deviceId: deviceId, accept: accept)
  }

  /// Drops our client link and stops reconnecting. CoreBluetooth can't drop a central
  /// connected to our service; it stays until the remote side disconnects.
  private func disconnect(_ deviceId: String) {
    guard let uuid = UUID(uuidString: deviceId) else { return }
    forgottenPeripherals.insert(uuid)
    userInitiated.remove(uuid)
    pendingConnectIds.remove(uuid)
    if let peripheral = peripherals[uuid] {
      centralManager.cancelPeripheralConnection(peripheral)
    }
    emitStatus()
  }

  /// Automatic connects target app-paired peers the engine has no link to (6.3, 9절).
  /// CoreBluetooth's connect doesn't time out, so this waits for them to show up.
  private func reconnectPeers() {
    guard centralEnabled, centralManager.state == .poweredOn else { return }
    for peer in store.peers() where engine.shouldReconnect(peerId: peer.peerId) {
      guard let uuid = UUID(uuidString: peripheralIds[peer.peerId.description] ?? peer.deviceId),
        !forgottenPeripherals.contains(uuid),
        let peripheral = peripherals[uuid] ?? centralManager.retrievePeripherals(withIdentifiers: [uuid]).first
      else { continue }
      peripherals[uuid] = peripheral
      if peripheral.state == .disconnected {
        centralManager.connect(peripheral, options: nil)
      }
    }
  }

  // MARK: - Links

  private func clientLinkUp(_ uuid: UUID) {
    guard let peripheral = peripherals[uuid], peripheral.state == .connected else { return }
    if let old = clientLinkIds.removeValue(forKey: uuid) {
      linkTargets.removeValue(forKey: old)
      engine.linkDown(linkId: old)
    }
    let linkId = nextLinkId
    nextLinkId += 1
    clientLinkIds[uuid] = linkId
    linkTargets[linkId] = .client(uuid)
    // A write with response must fit one ATT packet (no long writes, 4절), which is
    // what the without-response length reports: MTU - 3.
    engine.linkUp(
      linkId: linkId, role: .central, deviceId: uuid.uuidString,
      maxFrameSize: Frames.frameSize(packetLength: peripheral.maximumWriteValueLength(for: .withoutResponse)),
      userInitiated: userInitiated.contains(uuid))
  }

  private func clientLinkDown(_ uuid: UUID) {
    guard let linkId = clientLinkIds.removeValue(forKey: uuid) else { return }
    linkTargets.removeValue(forKey: linkId)
    engine.linkDown(linkId: linkId)
  }

  private func serverLinkUp(_ uuid: UUID) {
    guard let central = subscribedCentrals[uuid], serverLinkIds[uuid] == nil else { return }
    let linkId = nextLinkId
    nextLinkId += 1
    serverLinkIds[uuid] = linkId
    linkTargets[linkId] = .server(uuid)
    engine.linkUp(
      linkId: linkId, role: .peripheral, deviceId: uuid.uuidString,
      maxFrameSize: Frames.frameSize(packetLength: central.maximumUpdateValueLength), userInitiated: false)
  }

  private func serverLinkDown(_ uuid: UUID) {
    guard let linkId = serverLinkIds.removeValue(forKey: uuid) else { return }
    linkTargets.removeValue(forKey: linkId)
    pendingNotifications.removeAll { $0.linkId == linkId }
    engine.linkDown(linkId: linkId)
  }

  // MARK: - EngineHost

  func writeFrame(linkId: Int, frame: Data) {
    switch linkTargets[linkId] {
    case .client(let uuid):
      guard let peripheral = peripherals[uuid], peripheral.state == .connected,
        let characteristic = characteristics[uuid]
      else { return failWrite(linkId) }
      // Answered by didWriteValueFor; the engine has at most one frame out per link.
      peripheral.writeValue(frame, for: characteristic, type: .withResponse)
    case .server(let uuid):
      guard let central = subscribedCentrals[uuid], frameCharacteristic != nil else { return failWrite(linkId) }
      pendingNotifications.append((linkId: linkId, data: frame, central: central))
      flushNotifications()
    case nil:
      failWrite(linkId)
    }
  }

  private func failWrite(_ linkId: Int) {
    DispatchQueue.main.async { [weak self] in self?.engine.frameWritten(linkId: linkId, success: false) }
  }

  /// Sends queued notifications in order until the transmit queue is full;
  /// peripheralManagerIsReady(toUpdateSubscribers:) resumes. iOS has no per-
  /// notification callback, so a notification counts as written once it's queued.
  private func flushNotifications() {
    guard let characteristic = frameCharacteristic else { return }
    while let next = pendingNotifications.first {
      guard peripheralManager.updateValue(next.data, for: characteristic, onSubscribedCentrals: [next.central]) else {
        return
      }
      pendingNotifications.removeFirst()
      let linkId = next.linkId
      DispatchQueue.main.async { [weak self] in self?.engine.frameWritten(linkId: linkId, success: true) }
    }
  }

  func closeLink(linkId: Int) {
    guard let target = linkTargets.removeValue(forKey: linkId) else { return }
    log("Closing link \(linkId) (\(target))")
    switch target {
    case .client(let uuid):
      if clientLinkIds[uuid] == linkId {
        clientLinkIds.removeValue(forKey: uuid)
      }
      if let peripheral = peripherals[uuid] {
        centralManager.cancelPeripheralConnection(peripheral)
      }
    case .server(let uuid):
      // CoreBluetooth can't disconnect a central; the protocol leaves closing to it.
      if serverLinkIds[uuid] == linkId {
        serverLinkIds.removeValue(forKey: uuid)
      }
      pendingNotifications.removeAll { $0.linkId == linkId }
    }
    emitStatus()
  }

  func localIdentity() -> LocalIdentity {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    return LocalIdentity(name: deviceName, platform: Platform.ios, appVersion: version)
  }

  /// 6.3: iOS can only ask while the app is on screen (no notification flow yet);
  /// otherwise the peer gets REJECT(CANNOT_PROMPT).
  func canPrompt() -> Bool {
    UIApplication.shared.applicationState == .active && eventSink != nil
  }

  /// iOS has no AIDL, so it receives no app messages and no built-in paths yet.
  func localCaps() -> Capabilities { Capabilities(builtins: [], apps: []) }

  func deliver(peerId: PeerId, data: DataEnvelope, done: @escaping (Int) -> Void) {
    done(data.path.hasPrefix("/") ? DeliveryStatus.unsupported : DeliveryStatus.noReceiver)
  }

  func onEvent(_ event: EngineEvent) {
    switch event {
    case .connected(let deviceId, let peerId, _):
      // Remember where we reach this peer as a central, for reconnects.
      if let uuid = UUID(uuidString: deviceId), clientLinkIds[uuid] != nil {
        userInitiated.remove(uuid)
        peripheralIds[peerId.description] = deviceId
        prefs.set(peripheralIds, forKey: peripheralIdsKey)
      }
      emitDartEvent(event)
      schedulePeersEvent()
      emitStatus()
    case .disconnected:
      emitDartEvent(event)
      schedulePeersEvent()
      emitStatus()
      DispatchQueue.main.async { [weak self] in self?.reconnectPeers() }
    case .peersChanged:
      schedulePeersEvent()
    default:
      emitDartEvent(event)
    }
  }

  /// Also sent to Dart as `log`, which prints it outside release builds: on a device,
  /// that's where `flutter run`/`flutter drive` show it.
  func log(_ message: String) {
    NSLog("[BLE] %@", message)
    emit(type: "log", payload: ["message": message])
  }

  private func emitDartEvent(_ event: EngineEvent) {
    switch event {
    case .connected(let deviceId, let peerId, let name):
      emit(type: "connected", payload: ["deviceId": deviceId, "peerId": peerId.description, "name": name])
    case .disconnected(let deviceId):
      emit(type: "disconnected", payload: ["deviceId": deviceId])
    case .pairingRequest(let deviceId, let peerId, let name, let code, let repair):
      emit(type: "pairingRequest", payload: [
        "deviceId": deviceId, "peerId": peerId.description, "name": name, "code": code, "repair": repair,
      ])
    case .pairingResult(let deviceId, let peerId, let result):
      emit(type: "pairingResult", payload: ["deviceId": deviceId, "peerId": peerId.description, "result": result])
    case .peerRejected(let deviceId, let reason, let byPeer):
      emit(type: "peerRejected", payload: ["deviceId": deviceId, "reason": RejectReason.name(reason), "byPeer": byPeer])
    case .peerUnpaired(let deviceId, _):
      emit(type: "peerUnpaired", payload: ["deviceId": deviceId])
    case .error(let message):
      emit(type: "error", payload: ["message": message])
    case .peersChanged:
      emitPeers()
    }
  }

  private var peersEventPending = false

  // A session start changes the peers several times in a row; send one list.
  private func schedulePeersEvent() {
    guard !peersEventPending else { return }
    peersEventPending = true
    DispatchQueue.main.async { [weak self] in
      self?.peersEventPending = false
      self?.emitPeers()
    }
  }

  private func emitPeers() {
    let peers = engine.peerSummaries().map { summary -> [String: Any] in
      let state: String
      switch summary.peer.state {
      case .paired: state = "paired"
      case .repairNeeded: state = "repairNeeded"
      case .badMac: state = "badMac"
      case .unpairedByPeer: state = "unpairedByPeer"
      }
      return [
        "peerId": summary.peer.peerId.description,
        "deviceId": summary.peer.deviceId,
        "name": summary.peer.name,
        "platform": summary.peer.platform,
        "state": state,
        "connected": summary.connected,
      ]
    }
    emit(type: "peers", payload: ["peers": peers])
  }

  /// Ends Dart's connecting state for an attempt that never reached a session.
  private func emitDisconnected(_ deviceId: String) {
    if !engine.isConnected(deviceId: deviceId) {
      emit(type: "disconnected", payload: ["deviceId": deviceId])
    }
  }

  // MARK: - Advertising and scanning

  private func startAdvertisingIfPossible() {
    guard peripheralManager.state == .poweredOn else { return }
    guard serviceAdded else {
      // Advertising starts from didAdd once the service is published, so a central
      // that connects right away finds the characteristic.
      addFrameServiceIfNeeded()
      return
    }
    guard !peripheralManager.isAdvertising else { return }
    peripheralManager.startAdvertising([
      CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
      CBAdvertisementDataLocalNameKey: deviceName,
    ])
  }

  private func addFrameServiceIfNeeded() {
    guard !serviceAdded, !addingService else { return }
    // Like the Android server: writes and subscriptions need an encrypted (bonded)
    // link, so an unbonded central is asked to pair first.
    let characteristic = CBMutableCharacteristic(
      type: frameCharacteristicUUID,
      properties: [.write, .notifyEncryptionRequired],
      value: nil,
      permissions: [.writeEncryptionRequired]
    )
    let service = CBMutableService(type: serviceUUID, primary: true)
    service.characteristics = [characteristic]
    frameCharacteristic = characteristic
    addingService = true
    peripheralManager.add(service)
  }

  /// Forgets the published service and its subscribers, e.g. after advertising is
  /// turned off or Bluetooth powers down (which drops published services).
  private func resetPeripheralRole() {
    serviceAdded = false
    addingService = false
    frameCharacteristic = nil
    pendingNotifications.removeAll()
    let centrals = Array(subscribedCentrals.keys)
    subscribedCentrals.removeAll()
    centrals.forEach(serverLinkDown)
  }

  private func startScanningIfPossible() {
    guard centralManager.state == .poweredOn else { return }
    centralManager.scanForPeripherals(withServices: [serviceUUID], options: [
      CBCentralManagerScanOptionAllowDuplicatesKey: false
    ])
    isScanning = true
    emitStatus()
    scheduleScanRefresh()
  }

  private func emit(type: String, payload: [String: Any]) {
    var event: [String: Any] = ["type": type]
    payload.forEach { event[$0.key] = $0.value }
    // Without a listener, events are dropped: they describe state that initialize
    // replays.
    eventSink?(event)
  }

  private var scanRefreshTimer: Timer?

  /// Without duplicates, a scan reports each peripheral once; restarting it every 30 s
  /// in the foreground reports devices that are still there again, so Dart can drop
  /// the ones that went away. (Background scans ignore duplicates anyway.)
  private func scheduleScanRefresh() {
    scanRefreshTimer?.invalidate()
    scanRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      guard let self, self.centralEnabled, self.isScanning,
        UIApplication.shared.applicationState == .active,
        self.centralManager.state == .poweredOn
      else { return }
      self.centralManager.stopScan()
      self.centralManager.scanForPeripherals(withServices: [self.serviceUUID], options: [
        CBCentralManagerScanOptionAllowDuplicatesKey: false
      ])
    }
  }

  /// Same shape as the Android service's status: Dart builds the label from it.
  private func emitStatus() {
    emit(type: "status", payload: [
      "advertising": isAdvertising,
      "scanning": isScanning,
      "connectedCount": Set(engine.connectedSessions().compactMap {
        if case .connected(_, let peerId, _) = $0 { return peerId } else { return nil }
      }).count,
      "bluetoothOn": bluetoothOn,
    ])
  }
}

extension IOSBleBackgroundManager: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      bluetoothOn = true
      if centralEnabled {
        startScanningIfPossible()
      }
      let pending = pendingConnectIds
      pendingConnectIds.removeAll()
      pending.forEach { connectDevice($0.uuidString, pair: userInitiated.contains($0)) }
      // Links restored by state restoration lost their session with the old process;
      // subscribe again, which starts a new handshake.
      peripherals.values
        .filter { $0.state == .connected && clientLinkIds[$0.identifier] == nil }
        .forEach { $0.discoverServices([serviceUUID]) }
      reconnectPeers()
    case .poweredOff:
      // CoreBluetooth drops every link without calling didDisconnectPeripheral.
      characteristics.removeAll()
      Array(clientLinkIds.keys).forEach(clientLinkDown)
      isScanning = false
      bluetoothOn = false
      emitStatus()
    default:
      break
    }
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    // Commands have to wait for poweredOn; centralManagerDidUpdateState resumes these.
    let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
    for peripheral in restored {
      peripheral.delegate = self
      peripherals[peripheral.identifier] = peripheral
    }
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    log("Failed to connect to \(peripheral.identifier): \(error?.localizedDescription ?? "no error")")
    userInitiated.remove(peripheral.identifier)
    if reportBondLossIfNeeded(peripheral, error: error) {
      return
    }
    emit(type: "error", payload: [
      "message": "Connection to \(peripheral.identifier.uuidString) failed: \(error?.localizedDescription ?? "unknown error")"
    ])
    emitDisconnected(peripheral.identifier.uuidString)
  }

  /// The peer removed its pairing with us: reconnecting can't work until the user
  /// pairs again, so stop reconnecting it and tell Dart (same event as Android).
  private func reportBondLossIfNeeded(_ peripheral: CBPeripheral, error: Error?) -> Bool {
    guard (error as? CBError)?.code == .peerRemovedPairingInformation else { return false }
    forgottenPeripherals.insert(peripheral.identifier)
    emit(type: "bondLost", payload: ["deviceId": peripheral.identifier.uuidString])
    emitDisconnected(peripheral.identifier.uuidString)
    return true
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    peripherals[peripheral.identifier] = peripheral
    // Android puts its name in the scan response; peripheral.name is only the cached
    // GAP name, which a peer that was never connected doesn't have yet.
    let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
    emit(type: "discovered", payload: ["deviceId": peripheral.identifier.uuidString, "name": name])
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    log("Connected to \(peripheral.identifier)")
    subscribeAttempts.removeValue(forKey: peripheral.identifier)
    peripheral.delegate = self
    peripheral.discoverServices([serviceUUID])
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    let id = peripheral.identifier
    log("Disconnected from \(id): \(error?.localizedDescription ?? "no error")")
    characteristics.removeValue(forKey: id)
    clientLinkDown(id)
    userInitiated.remove(id)
    if reportBondLossIfNeeded(peripheral, error: error) {
      return
    }
    emitDisconnected(id.uuidString)
    emitStatus()
    reconnectPeers()
  }
}

extension IOSBleBackgroundManager: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    switch peripheral.state {
    case .poweredOn:
      bluetoothOn = true
      if advertisingEnabled {
        startAdvertisingIfPossible()
      }
    case .poweredOff:
      resetPeripheralRole()
      isAdvertising = false
      bluetoothOn = false
      emitStatus()
    default:
      break
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
    let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
    let characteristic = services
      .first { $0.uuid == serviceUUID }?
      .characteristics?
      .first { $0.uuid == frameCharacteristicUUID } as? CBMutableCharacteristic
    if let characteristic {
      frameCharacteristic = characteristic
      serviceAdded = true
      // Their sessions died with the old process; a new HELLO_c revives each link.
      characteristic.subscribedCentrals?.forEach {
        subscribedCentrals[$0.identifier] = $0
        serverLinkUp($0.identifier)
      }
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    addingService = false
    if let error {
      frameCharacteristic = nil
      emit(type: "error", payload: ["message": "Failed to add GATT service: \(error.localizedDescription)"])
      return
    }
    serviceAdded = true
    if advertisingEnabled {
      startAdvertisingIfPossible()
    }
  }

  func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let error {
      emit(type: "error", payload: ["message": "Advertising failed: \(error.localizedDescription)"])
      return
    }
    isAdvertising = true
    emitStatus()
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
    guard characteristic.uuid == frameCharacteristicUUID else { return }
    subscribedCentrals[central.identifier] = central
    serverLinkUp(central.identifier)
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
    guard characteristic.uuid == frameCharacteristicUUID else { return }
    log("\(central.identifier) unsubscribed")
    subscribedCentrals.removeValue(forKey: central.identifier)
    serverLinkDown(central.identifier)
    emitStatus()
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    guard let first = requests.first else { return }
    guard requests.allSatisfy({ $0.characteristic.uuid == frameCharacteristicUUID && $0.offset == 0 }) else {
      // Every frame fits in one ATT write (4절); long writes aren't part of it.
      peripheral.respond(to: first, withResult: .requestNotSupported)
      return
    }
    peripheral.respond(to: first, withResult: .success)
    for request in requests {
      let id = request.central.identifier
      // A central that resubscribed before we noticed may write first.
      if serverLinkIds[id] == nil, subscribedCentrals[id] != nil {
        serverLinkUp(id)
      }
      if let linkId = serverLinkIds[id], let value = request.value {
        engine.frameReceived(linkId: linkId, frame: value)
      }
    }
  }

  func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    flushNotifications()
  }
}

extension IOSBleBackgroundManager: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard error == nil else { return }
    guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else { return }
    peripheral.discoverCharacteristics([frameCharacteristicUUID], for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard error == nil else { return }
    let id = peripheral.identifier
    guard let characteristic = service.characteristics?.first(where: { $0.uuid == frameCharacteristicUUID }) else {
      // Same service, older protocol (the characteristic UUID changed with it).
      emit(type: "error", payload: ["message": "\(peripheral.name ?? id.uuidString) runs an incompatible version of the app"])
      forgottenPeripherals.insert(id)
      centralManager.cancelPeripheralConnection(peripheral)
      return
    }
    characteristics[id] = characteristic
    if characteristic.isNotifying {
      clientLinkUp(id)
    } else {
      peripheral.setNotifyValue(true, for: characteristic)
    }
  }

  // The peer's GATT database changed, typically because its app restarted and
  // registered a new server. Our session went with the old one: discover and
  // subscribe again, which starts a new handshake.
  func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
    guard invalidatedServices.contains(where: { $0.uuid == serviceUUID }) else { return }
    log("\(peripheral.identifier) changed its services; subscribing again")
    characteristics.removeValue(forKey: peripheral.identifier)
    peripheral.discoverServices([serviceUUID])
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    guard characteristic.uuid == frameCharacteristicUUID else { return }
    let id = peripheral.identifier
    guard let error else {
      subscribeAttempts.removeValue(forKey: id)
      if characteristic.isNotifying {
        clientLinkUp(id)
      }
      return
    }
    // The peer requires an encrypted link. The first attempt makes iOS start pairing
    // but fails itself, and CoreBluetooth doesn't retry it, so retry until pairing is
    // done (the system dialog times out after about 30 s).
    let code = (error as? CBATTError)?.code
    let attempts = subscribeAttempts[id, default: 0] + 1
    log("Subscribing to \(id) failed (attempt \(attempts)): \(error.localizedDescription)")
    if code == .insufficientAuthentication || code == .insufficientEncryption, attempts <= 30 {
      subscribeAttempts[id] = attempts
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        guard let self, peripheral.state == .connected, let current = self.characteristics[id] else { return }
        peripheral.setNotifyValue(true, for: current)
      }
      return
    }
    subscribeAttempts.removeValue(forKey: id)
    emit(type: "error", payload: ["message": "Subscribing to \(id.uuidString) failed: \(error.localizedDescription)"])
    userInitiated.remove(id)
    emitDisconnected(id.uuidString)
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    guard characteristic.uuid == frameCharacteristicUUID, let linkId = clientLinkIds[peripheral.identifier] else { return }
    if let error {
      log("Frame to \(peripheral.identifier) failed: \(error.localizedDescription)")
    }
    engine.frameWritten(linkId: linkId, success: error == nil)
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard error == nil, characteristic.uuid == frameCharacteristicUUID,
      let value = characteristic.value, let linkId = clientLinkIds[peripheral.identifier]
    else { return }
    engine.frameReceived(linkId: linkId, frame: value)
  }
}
